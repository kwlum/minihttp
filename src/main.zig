const std = @import("std");
const ascii = std.ascii;
const http = std.http;
const io = std.io;
const mem = std.mem;
const os = std.os;

const httpparser = @import("httpparser");
const xev = @import("xev");

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

    pub fn iterator(self: *const Headers) Iterator {
        return .{
            .slice = self.inner[0..self.pos],
            .index = 0,
        };
    }

    pub fn put(self: *Headers, name: []const u8, value: []const u8) Error!void {
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

        _ = try fbs.write("\r\n");
        _ = try fbs.write(body);

        return fbs.getWritten();
    }
};

const BufferPool = std.heap.MemoryPool([4096]u8);
const CompletionPool = std.heap.MemoryPool(xev.Completion);

fn Client(comptime T: type) type {
    return struct {
        id: usize,
        allocator: mem.Allocator,
        body_buffer: []u8,
        service: T,
        buffer_pool: *BufferPool,
        completion_pool: *CompletionPool,

        const Self = @This();

        fn init(
            id: usize,
            allocator: mem.Allocator,
            buffer_pool: *BufferPool,
            completion_pool: *CompletionPool,
            service: T,
        ) !*Client(T) {
            var client = try allocator.create(Client(T));
            errdefer allocator.destroy(client);

            var body_buffer = try buffer_pool.create();

            client.* = .{
                .id = id,
                .allocator = allocator,
                .body_buffer = body_buffer,
                .service = service,
                .buffer_pool = buffer_pool,
                .completion_pool = completion_pool,
            };

            return client;
        }

        fn deinit(self: *Self) void {
            self.destroyBuffer(self.body_buffer);
            self.allocator.destroy(self);
        }

        fn destroyBuffer(self: *Self, buffer: []const u8) void {
            self.buffer_pool.destroy(
                @alignCast(
                    BufferPool.item_alignment,
                    @intToPtr(*[4096]u8, @ptrToInt(buffer.ptr)),
                ),
            );
        }

        fn close(self: *Self, ev_loop: *xev.Loop, socket: xev.TCP) void {
            std.log.debug("Client[{}].close", .{self.id});

            const completion = self.completion_pool.create() catch unreachable;
            socket.close(ev_loop, completion, Self, self, onClose);
        }

        fn receive(self: *Self, ev_loop: *xev.Loop, socket: xev.TCP) void {
            std.log.debug("Client[{}].receive [{}]", .{ self.id, std.Thread.getCurrentId() });

            const completion = self.completion_pool.create() catch unreachable;
            const read_buffer = self.buffer_pool.create() catch unreachable;
            socket.read(
                ev_loop,
                completion,
                .{ .slice = read_buffer },
                Self,
                self,
                onReceive,
            );
        }

        fn send(
            self: *Self,
            ev_loop: *xev.Loop,
            socket: xev.TCP,
            buffer: []const u8,
            write_count: usize,
        ) void {
            std.log.debug("Client[{}].send [{}]", .{ self.id, std.Thread.getCurrentId() });

            const completion = self.completion_pool.create() catch unreachable;
            socket.write(
                ev_loop,
                completion,
                .{ .slice = buffer[0..write_count] },
                Self,
                self,
                onSend,
            );
            std.log.debug("Client[{}].send - done", .{self.id});
        }

        fn onReceive(
            self_: ?*Self,
            ev_loop: *xev.Loop,
            completion: *xev.Completion,
            socket: xev.TCP,
            read_buffer: xev.ReadBuffer,
            result: xev.ReadError!usize,
        ) xev.CallbackAction {
            const self = self_.?;
            std.log.debug("Client[{}].onReceive [{}]", .{ self.id, std.Thread.getCurrentId() });
            defer {
                if (completion.state() == .dead) {
                    self.completion_pool.destroy(completion);
                }

                self.destroyBuffer(read_buffer.slice);
            }

            const count = result catch {
                // std.log.err("Client.onReceive, result :: {}", .{err});
                self.close(ev_loop, socket);
                return .disarm;
            };

            if (count == 0) {
                self.close(ev_loop, socket);
                return .disarm;
            }

            const read_slice = read_buffer.slice;

            // decode buffer.
            const request = HttpCodec.decode(read_slice[0..count]) catch |err| {
                std.log.err("Client.onTask - decode :: {}", .{err});
                return .disarm;
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
            @call(.auto, self.service.handle, .{ request, &response }) catch |err| {
                std.log.err("Client.dispatchRequest - handle fn :: {}", .{err});
                return .disarm;
            };

            const write_buffer = self.buffer_pool.create() catch unreachable;
            const output = HttpCodec.encode(response, body_fbs.getWritten(), write_buffer) catch |err| {
                std.log.err("Client.dispatchRequest - HttpCodec.encode :: {}", .{err});
                return .disarm;
            };

            self.send(ev_loop, socket, write_buffer, output.len);

            return .disarm;
        }

        fn onSend(
            self_: ?*Self,
            ev_loop: *xev.Loop,
            completion: *xev.Completion,
            socket: xev.TCP,
            write_buffer: xev.WriteBuffer,
            result: xev.WriteError!usize,
        ) xev.CallbackAction {
            const self = self_.?;
            std.log.debug("Client[{}].onSend [{}]", .{ self.id, std.Thread.getCurrentId() });
            defer {
                std.log.debug("onSend - completion :: {}", .{completion.state()});
                if (completion.state() == .dead) {
                    self.completion_pool.destroy(completion);
                }

                self.destroyBuffer(write_buffer.slice);
            }

            _ = result catch |err| {
                std.log.err("Client.onSend - result :: {}", .{err});
                return .disarm;
            };

            self.receive(ev_loop, socket);
            return .disarm;
        }

        fn onClose(
            self_: ?*Self,
            _: *xev.Loop,
            completion: *xev.Completion,
            _: xev.TCP,
            result: xev.CloseError!void,
        ) xev.CallbackAction {
            const self = self_.?;
            std.log.debug("Client[{}].onClose [{}]", .{ self.id, std.Thread.getCurrentId() });

            defer {
                std.log.debug("onClose - completion :: {}", .{completion.state()});
                if (completion.state() == .dead) {
                    self.completion_pool.destroy(completion);
                }

                self.deinit();
            }

            _ = result catch |err| {
                std.log.err("Client.onClose, result :: {}", .{err});
                return .disarm;
            };

            return .disarm;
        }
    };
}

fn Server(comptime T: type) type {
    return struct {
        allocator: mem.Allocator,
        buffer_pool: *BufferPool,
        completion_pool: *CompletionPool,
        socket: xev.TCP,
        service: T,
        next_id: usize = 0,

        const Self = @This();

        fn init(
            allocator: mem.Allocator,
            buffer_pool: *BufferPool,
            completion_pool: *CompletionPool,
            socket: xev.TCP,
            service: T,
        ) !Server(T) {
            return .{
                .allocator = allocator,
                .service = service,
                .buffer_pool = buffer_pool,
                .completion_pool = completion_pool,
                .socket = socket,
                .next_id = 0,
            };
        }

        fn accept(self: *Self, ev_loop: *xev.Loop) void {
            const completion = self.completion_pool.create() catch unreachable;
            self.socket.accept(ev_loop, completion, Self, self, onAccept);
        }

        fn onAccept(
            self_: ?*Self,
            ev_loop: *xev.Loop,
            completion: *xev.Completion,
            result: xev.AcceptError!xev.TCP,
        ) xev.CallbackAction {
            const self = self_.?;
            std.log.debug("Server.onAccept [{}]", .{std.Thread.getCurrentId()});

            defer {
                if (completion.state() == .dead) {
                    self.completion_pool.destroy(completion);
                }
            }

            const client_socket = result catch |err| {
                std.log.err("Server.acceptCallback - result:: {}", .{err});
                return .disarm;
            };

            self.next_id += 1;
            var client = Client(T).init(
                self.next_id,
                self.allocator,
                self.buffer_pool,
                self.completion_pool,
                self.service,
            ) catch |err| {
                std.log.err("Server.acceptCallback - Client.init:: {}", .{err});
                return .disarm;
            };

            client.receive(ev_loop, client_socket);
            self.accept(ev_loop);

            return .disarm;
        }
    };
}

pub fn run(
    comptime T: type,
    allocator: mem.Allocator,
    address: std.net.Address,
    service: T,
) !void {
    const tcp_socket = try xev.TCP.init(address);
    try tcp_socket.bind(address);
    try tcp_socket.listen(std.os.linux.SOMAXCONN);

    var ev_loop = try xev.Loop.init(.{});
    var buffer_pool = try BufferPool.initPreheated(allocator, 32);
    var completion_pool = CompletionPool.init(allocator);

    var server = try Server(T).init(allocator, &buffer_pool, &completion_pool, tcp_socket, service);

    server.accept(&ev_loop);
    std.log.info("Server started at port {d}", .{address.getPort()});

    try ev_loop.run(.until_done);
}
