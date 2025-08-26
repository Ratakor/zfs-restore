const std = @import("std");
const known_folders = @import("known_folders");
const sizeify = @import("sizeify");

pub const axe = @import("axe").Axe(.{
    .mutex = .{ .function = .progress_stderr },
    .format = "%t %l%s:%L %m\n",
    .time_format = .{ .gofmt = .rfc3339 },
});

const log_file_name = "zfs-restore.log";
var log_file_buffer: [256]u8 = undefined;
var log_file_writer: std.fs.File.Writer = undefined; // set in init

var fba_buffer: [4 * 4096]u8 = undefined;
var fba: std.heap.FixedBufferAllocator = .init(&fba_buffer);

pub fn init() !void {
    const allocator = fba.allocator();

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

    axe.debugAt(@src(), "Used {f} of memory", .{sizeify.fmt(fba.end_index, .binary_short)});
}

// noop as axe shouldn't be deinitialized if set in std_options & using time or
// additional writers
pub fn deinit() void {
    // log_file_writer.file.close();
    // axe.deinit(allocator);
}
