const std = @import("std");
const known_folders = @import("known_folders");

pub const axe = @import("axe").Axe(.{
    .mutex = .{ .function = .progress_stderr },
    .format = "%t %l%s:%L %m\n",
    .time_format = .{ .gofmt = .rfc3339 },
});

const log_file_name = "zfs-restore.log";
var log_file_buffer: [256]u8 = undefined;
var log_file_writer: std.fs.File.Writer = undefined;

pub fn init(allocator: std.mem.Allocator) !void {
    var log_dir = try known_folders.open(allocator, .logs, .{}) orelse return error.EnvironmentVariableNotFound;
    defer log_dir.close();

    const log_file = log_dir.createFile(log_file_name, .{
        .exclusive = true,
        .mode = 0o644,
    }) catch |err| switch (err) {
        error.PathAlreadyExists => try log_dir.openFile(log_file_name, .{ .mode = .write_only }),
        else => return err,
    };
    errdefer log_file.close();

    try log_file.seekFromEnd(0);
    log_file_writer = log_file.writerStreaming(&log_file_buffer);

    try axe.init(allocator, &.{&log_file_writer.interface}, null);
}

pub fn deinit(allocator: std.mem.Allocator) void {
    log_file_writer.file.close();
    axe.deinit(allocator);
}
