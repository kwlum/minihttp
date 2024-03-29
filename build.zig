const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("minihttp", .{
        .source_file = .{ .path = "src/main.zig" },
    });

    const httpparser_dep = b.dependency("httpparser", .{
        .target = target,
        .optimize = optimize,
    });

    const xev_dep = b.dependency("xev", .{
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addStaticLibrary(.{
        .name = "minihttp",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    lib.addModule("httpparser", httpparser_dep.module("httpparser"));
    lib.addModule("xev", xev_dep.module("xev"));
    lib.install();

    const main_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);
}
