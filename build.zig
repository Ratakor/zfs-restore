const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const axe = b.dependency("axe", .{
        .target = target,
        .optimize = optimize,
    }).module("axe");
    const sizeify = b.dependency("sizeify", .{
        .target = target,
        .optimize = optimize,
    }).module("sizeify");
    const zeit = b.dependency("zeit", .{
        .target = target,
        .optimize = optimize,
    }).module("zeit");
    const clap = b.dependency("clap", .{
        .target = target,
        .optimize = optimize,
    }).module("clap");

    const exe = b.addExecutable(.{
        .name = "zfs-restore",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "axe", .module = axe },
                .{ .name = "sizeify", .module = sizeify },
                .{ .name = "zeit", .module = zeit },
                .{ .name = "clap", .module = clap },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{ .root_module = exe.root_module });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);

    const fmt_step = b.step("fmt", "Format all source files");
    fmt_step.dependOn(&b.addFmt(.{ .paths = &.{ "build.zig", "src" } }).step);
}
