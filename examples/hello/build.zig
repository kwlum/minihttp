const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const httpparser_dep = b.dependency("httpparser", .{
        .target = target,
        .optimize = optimize,
    });

    const xev_dep = b.dependency("xev", .{
        .target = target,
        .optimize = optimize,
    });

    const minihttp_mod = b.createModule(.{
        .source_file = .{ .path = "../../src/main.zig" },
        .dependencies = &[_]std.build.ModuleDependency{
            .{
                .name = "httpparser",
                .module = httpparser_dep.module("httpparser"),
            },
            .{
                .name = "xev",
                .module = xev_dep.module("xev"),
            },
        },
    });

    const exe = b.addExecutable(.{
        .name = "hello",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    exe.addModule("minihttp", minihttp_mod);
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&exe_tests.step);
}
