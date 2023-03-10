const std = @import("std");
const ascii = std.ascii;
const http = std.http;
const io = std.io;
const mem = std.mem;
const os = std.os;

const httpparser = @import("httpparser");
const IO = @import("linux.zig").IO;

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

const Headers = struct {
    inner: [64]httpparser.Header,
    pos: usize,

    const Error = error{
        TooManyHeaders,
    };

    const Iterator = struct {
        slice: []const httpparser.Header,
        index: usize,

        fn next(self: *Iterator) ?Header {
            if (self.index < self.slice.len) {
                const i = self.index;
                self.index += 1;

                return .{
                    .name = self.slice[i].name,
                    .value = self.slice[i].value,
                };
            } else {
                return null;
            }
        }
    };

    fn init() Headers {
        return .{
            .inner = undefined,
            .pos = 0,
        };
    }

    fn iterator(self: *const Headers) Iterator {
        return .{
            .slice = self.inner[0..self.pos],
            .index = 0,
        };
    }

    fn put(self: *Headers, name: []const u8, value: []const u8) Error!void {
        if (self.pos >= self.inner.len) return Error.TooManyHeaders;

        self.inner[self.pos].name = name;
        self.inner[self.pos].value = value;
        self.pos += 1;
    }
};

pub const Request = struct {
    method: http.Method,
    path: []const u8,
    headers: Headers,
    body: []const u8,
};

pub const Response = struct {
    status: http.Status,
    headers: Headers,
    body: io.FixedBufferStream([]u8).Writer,
};

const HttpCodec = struct {
    fn decode(buffer: []const u8) !Request {
        var request: Request = undefined;
        request.headers = Headers.init();
        var http_request = httpparser.Request.init(&request.headers.inner);
        try http_request.parse(buffer);

        request.path = http_request.path orelse "/";
        request.body = http_request.payload orelse "";
        request.method = .GET; // default

        if (http_request.method) |a| {
            var lower_buf: [16]u8 = undefined;
            const method_string = ascii.lowerString(&lower_buf, a);

            request.method = if (mem.eql(u8, method_string, "get"))
                .GET
            else if (mem.eql(u8, method_string, "post"))
                .POST
            else if (mem.eql(u8, method_string, "put"))
                .PUT
            else if (mem.eql(u8, method_string, "delete"))
                .DELETE
            else if (mem.eql(u8, method_string, "head"))
                .HEAD
            else if (mem.eql(u8, method_string, "connect"))
                .CONNECT
            else if (mem.eql(u8, method_string, "options"))
                .OPTIONS
            else if (mem.eql(u8, method_string, "trace"))
                .TRACE
            else if (mem.eql(u8, method_string, "patch"))
                .PATCH
            else
                .GET;
        }

        return request;
    }

    fn encode(
        response: Response,
        body: []const u8,
        out_buffer: []u8,
    ) ![]const u8 {
        var fbs = io.fixedBufferStream(out_buffer);
        var writer = fbs.writer();
        try writer.print("HTTP/1.1 {d} {s}\r\n", .{
            @enumToInt(response.status),
            response.status.phrase() orelse "",
        });

        try writer.print("content-length: {d}\r\n", .{body.len});

        var headers_itr = response.headers.iterator();
        while (headers_itr.next()) |header| {
            try writer.print("{s}: {s}\r\n", .{ header.name, header.value });
        }

        try writer.writeAll("\r\n");
        try writer.writeAll(body);

        return fbs.getWritten();
    }
};

fn Client(comptime T: type) type {
    return struct {
        io_ring: *IO,
        socket: os.socket_t,
        allocator: mem.Allocator,
        completion: IO.Completion,
        in_buffer: []u8,
        out_buffer: []u8,
        body_buffer: []u8,
        all_buffer: []u8,
        service: T,

        const Self = @This();

        fn init(
            allocator: mem.Allocator,
            io_ring: *IO,
            socket: os.socket_t,
            service: T,
        ) !*Client(T) {
            var client = try allocator.create(Client(T));
            errdefer allocator.destroy(client);

            var buffer = try allocator.alloc(u8, 4096 * 3);
            var in_buffer = buffer[0..4096];
            var body_buffer = buffer[4096..8192];
            var out_buffer = buffer[8192..];
            client.* = .{
                .socket = socket,
                .allocator = allocator,
                .io_ring = io_ring,
                .in_buffer = in_buffer,
                .out_buffer = out_buffer,
                .body_buffer = body_buffer,
                .all_buffer = buffer,
                .completion = undefined,
                .service = service,
            };

            return client;
        }

        fn deinit(self: *Self) void {
            self.allocator.free(self.all_buffer);
            self.allocator.destroy(self);
        }

        fn run(self: *Self) void {
            self.receive();
        }

        fn receive(self: *Self) void {
            self.io_ring.recv(
                *Self,
                self,
                onReceive,
                &self.completion,
                self.socket,
                self.in_buffer,
            );
        }

        fn onReceive(self: *Self, completion: *IO.Completion, result: IO.RecvError!usize) void {
            const count = result catch {
                // std.log.err("Client.onReceive - {d}, result :: {}", .{ self.socket, err });
                self.io_ring.close(*Self, self, onClose, completion, self.socket);
                return;
            };

            if (count == 0) {
                std.log.debug("Client close connection - {d}.", .{self.socket});
                self.io_ring.close(*Self, self, onClose, completion, self.socket);
                return;
            }

            // decode buffer.
            const request = HttpCodec.decode(self.in_buffer[0..count]) catch |err| {
                std.log.err("Client.onReceive - decode :: {}", .{err});
                return;
            };

            // make response.
            var body_fbs = io.fixedBufferStream(self.body_buffer);
            var headers = Headers.init();
            var response: Response = .{
                .status = http.Status.ok,
                .headers = headers,
                .body = body_fbs.writer(),
            };

            // call the service.
            @call(.{}, self.service.handle, .{ request, &response }) catch |err| {
                std.log.err("Client.dispatchRequest - handle fn :: {}", .{err});
                return;
            };

            const output = HttpCodec.encode(response, body_fbs.getWritten(), self.out_buffer) catch |err| {
                std.log.err("Client.dispatchRequest - HttpCodec.encode :: {}", .{err});
                return;
            };

            self.io_ring.send(*Self, self, onSend, completion, self.socket, self.out_buffer[0..output.len]);
        }

        fn onSend(self: *Self, _: *IO.Completion, result: IO.SendError!usize) void {
            _ = result catch |err| {
                std.log.err("Client.onSend - result :: {}", .{err});
                return;
            };

            self.receive();
        }

        fn onClose(self: *Self, _: *IO.Completion, result: IO.CloseError!void) void {
            _ = result catch |err| {
                std.log.err("Client.onClose - {d}, result :: {}", .{ self.socket, err });
                return;
            };
            self.deinit();
        }
    };
}

fn Server(comptime T: type) type {
    return struct {
        socket: os.socket_t,
        io_ring: *IO,
        allocator: mem.Allocator,
        service: T,

        const Self = @This();

        fn init(allocator: mem.Allocator, io_ring: *IO, socket: os.socket_t, service: T) Server(T) {
            return .{
                .io_ring = io_ring,
                .socket = socket,
                .allocator = allocator,
                .service = service,
            };
        }

        fn run(self: *Self) !void {
            var completion: IO.Completion = undefined;
            self.io_ring.accept(*Self, self, onAccept, &completion, self.socket);
            while (true) try self.io_ring.tick();
        }

        fn onAccept(self: *Self, completion: *IO.Completion, result: IO.AcceptError!os.socket_t) void {
            const client_socket = result catch |err| {
                std.log.err("Server.acceptCallback - result:: {}", .{err});
                return;
            };
            var client = Client(T).init(self.allocator, self.io_ring, client_socket, self.service) catch |err| {
                std.log.err("Server.acceptCallback - Client.init:: {}", .{err});
                return;
            };
            client.run();
            self.io_ring.accept(*Self, self, onAccept, completion, self.socket);
        }
    };
}

pub fn run(
    comptime T: type,
    allocator: mem.Allocator,
    address: std.net.Address,
    service: T,
) !void {
    const socket = try os.socket(address.any.family, os.SOCK.STREAM | os.SOCK.CLOEXEC, 0);
    defer os.close(socket);

    try os.setsockopt(socket, os.SOL.SOCKET, os.SO.REUSEADDR, &mem.toBytes(@as(c_int, 1)));
    try os.bind(socket, &address.any, address.getOsSockLen());
    try os.listen(socket, 1);

    var io_ring = try IO.init(32, 0);
    defer io_ring.deinit();

    var server = Server(T).init(allocator, &io_ring, socket, service);
    std.log.info("Server started at port {d}", .{address.getPort()});
    try server.run();
}

// User App.
const HelloWorldService = struct {
    fn handle(_: *HelloWorldService, _: Request, response: *Response) !void {
        try response.headers.put("x-server", "zig-minihttp");
        try response.body.writeAll("Hello, World!");
        response.status = http.Status.ok;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const address = try std.net.Address.parseIp4("127.0.0.1", 8000);
    var service = HelloWorldService{};
    try run(*HelloWorldService, gpa.allocator(), address, &service);
}
