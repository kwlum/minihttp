const std = @import("std");

const minihttp = @import("minihttp");

const AppState = struct {
    message: []const u8,
};

pub const HelloWorldService = struct {
    state: *AppState = undefined,
    request: *minihttp.Request = undefined,
    response: *minihttp.Response = undefined,

    pub fn onRequest(self: *HelloWorldService) !void {
        try self.response.headers.put("x-server", "zig-minihttp");
        try self.response.body.writeAll(self.state.message);
        self.response.status = std.http.Status.ok;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const address = try std.net.Address.parseIp4("127.0.0.1", 8080);
    var state = AppState{
        .message = "Hello, World!",
    };
    try minihttp.run(AppState, &state, HelloWorldService, gpa.allocator(), address, 2);
}
