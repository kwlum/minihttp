const std = @import("std");

const minihttp = @import("minihttp");

const HelloWorldService = struct {
    pub fn handle(_: *HelloWorldService, _: minihttp.Request, response: *minihttp.Response) !void {
        try response.headers.put("x-server", "zig-minihttp");
        try response.body.writeAll("Hello, World!");
        response.status = std.http.Status.ok;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const address = try std.net.Address.parseIp4("127.0.0.1", 8080);
    var service = HelloWorldService{};
    try minihttp.run(*HelloWorldService, gpa.allocator(), address, &service, 2);
}
