const std = @import("std");
const mem = std.mem;
const os = std.os;

const IO = @import("linux.zig").IO;

const Client = struct {
    io_ring: *IO,
    socket: os.socket_t,
    allocator: mem.Allocator,
    completion: IO.Completion,
    buffer: []u8,

    fn init(allocator: mem.Allocator, io: *IO, socket: os.socket_t) !*Client {
        var client = try allocator.create(Client);
        errdefer allocator.destroy(client);

        var buffer = try allocator.alloc(u8, 4096);
        client.* = .{
            .socket = socket,
            .allocator = allocator,
            .io_ring = io,
            .buffer = buffer,
            .completion = undefined,
        };

        return client;
    }

    fn deinit(self: *Client) void {
        self.allocator.free(self.buffer);
        self.allocator.destroy(self);
    }

    fn run(self: *Client) void {
        self.receive();
    }

    fn receive(self: *Client) void {
        self.io_ring.recv(
            *Client,
            self,
            receiveCallback,
            &self.completion,
            self.socket,
            self.buffer,
        );
    }

    const message =
        \\HTTP/1.1 200 OK
        \\server: M
        \\content-length: 13
        \\content-type: text/plain
        \\
        \\Hello, world!
    ;

    fn receiveCallback(self: *Client, completion: *IO.Completion, result: IO.RecvError!usize) void {
        const count = result catch {
            // std.log.err("Client.receiveCallback - {d}, result :: {}", .{ self.socket, err });
            self.io_ring.close(*Client, self, closeCallback, completion, self.socket);
            return;
        };

        if (count == 0) {
            // std.log.info("Client close connection - {d}.", .{self.socket});
            self.io_ring.close(*Client, self, closeCallback, completion, self.socket);
            return;
        }
        // const message = self.buffer[0..count];
        // std.log.info("Client {} receive {} bytes: {s}", .{ self.socket, count, message });
        self.io_ring.send(*Client, self, sendCallback, completion, self.socket, message);
    }

    fn sendCallback(self: *Client, _: *IO.Completion, result: IO.SendError!usize) void {
        _ = result catch {
            // std.log.err("Client.sendCallback - result :: {}", .{err});
            return;
        };

        self.receive();
    }

    fn closeCallback(self: *Client, _: *IO.Completion, result: IO.CloseError!void) void {
        _ = result catch {
            // std.log.err("Client.closeCallback - {d}, result :: {}", .{ self.socket, err });
            return;
        };
        self.deinit();
    }
};

const Server = struct {
    socket: os.socket_t,
    io_ring: *IO,
    allocator: mem.Allocator,

    fn init(allocator: mem.Allocator, io: *IO, socket: os.socket_t) Server {
        return .{
            .io_ring = io,
            .socket = socket,
            .allocator = allocator,
        };
    }

    fn run(self: *Server) !void {
        var completion: IO.Completion = undefined;
        self.io_ring.accept(*Server, self, acceptCallback, &completion, self.socket);
        while (true) try self.io_ring.tick();
    }

    fn acceptCallback(self: *Server, completion: *IO.Completion, result: IO.AcceptError!os.socket_t) void {
        const client_socket = result catch {
            // std.log.err("Server.acceptCallback - result:: {}", .{err});
            return;
        };
        var client = Client.init(self.allocator, self.io_ring, client_socket) catch {
            // std.log.err("Server.acceptCallback - Client.init:: {}", .{err});
            return;
        };
        client.run();
        self.io_ring.accept(*Server, self, acceptCallback, completion, self.socket);
    }
};

pub fn main() !void {
    const address = try std.net.Address.parseIp4("127.0.0.1", 8080);
    const socket = try os.socket(address.any.family, os.SOCK.STREAM | os.SOCK.CLOEXEC, 0);
    defer os.close(socket);

    try os.setsockopt(socket, os.SOL.SOCKET, os.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    try os.bind(socket, &address.any, address.getOsSockLen());
    try os.listen(socket, 1);

    var io = try IO.init(32, 0);
    defer io.deinit();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var server = Server.init(gpa.allocator(), &io, socket);
    std.log.info("server started 8080", .{});
    try server.run();
}
