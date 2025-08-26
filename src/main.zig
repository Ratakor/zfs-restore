const std = @import("std");
const sizeify = @import("sizeify");
const _log = @import("log.zig");
const log = _log.axe;
const zfs = @import("zfs.zig");
const snap = @import("snapshots.zig");

pub const std_options: std.Options = .{
    .logFn = log.log,
};

pub fn main() !u8 {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try _log.init();
    defer _log.deinit();

    // TODO: use an arg parser
    ////////////////////////////////////////////////////////////////////////////

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next(); // progname

    const filename = args.next() orelse {
        log.err("Usage: zfs-restore <file>", .{});
        return 1;
    };
    log.debugAt(@src(), "Input file: {s}", .{filename});

    if (std.fs.cwd().access(filename, .{})) {
        log.warn("'{s}' already exist", .{filename});
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => {
            log.err("Error accessing file '{s}': {t}", .{ filename, err });
            return 1;
        },
    }

    const realpath = blk: {
        // TODO: fix that
        // resolve .. correctly like
        // zfs-restore ../somefile with cwd /home/user
        // should resolve to /home/somefile not /home/user/../somefile
        const wd = try std.fs.cwd().realpathAlloc(allocator, ".");
        defer allocator.free(wd);
        break :blk try std.fs.path.join(allocator, &.{ wd, filename });
    };
    defer allocator.free(realpath);
    log.debugAt(@src(), "realpath: {s}", .{realpath});

    ////////////////////////////////////////////////////////////////////////////

    const dataset = try zfs.findDataset(allocator, realpath);
    defer dataset.deinit(allocator);

    // TODO: we are here
    const entries = try snap.getEntries(allocator, dataset.mountpoint, realpath);
    defer {
        for (entries) |entry| {
            entry.deinit(allocator);
        }
        allocator.free(entries);
    }

    if (entries.len == 0) {
        log.info("No snapshots found for file: {s}", .{realpath});
        return 0;
    }

    std.mem.sort(snap.SnapshotEntry, entries, {}, snap.SnapshotEntry.oldestFirst);

    log.debugAt(@src(), "first entry: {s}", .{entries[0].name});

    // ask to restore
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buffer);

    // TODO: if entries.len == 1 ask a y/N question instead?
    // TODO: add a way to see the files before restoring?
    var i: usize = entries.len;
    for (entries) |entry| {
        i -= 1;
        try stdout.interface.print("{d: >4} {s} ({f})\n", .{
            i,
            entry.name,
            sizeify.fmt(entry.size, .decimal_short),
        });
    }
    try stdout.interface.print("Which version to restore [0..{d}]: ", .{entries.len - 1});
    try stdout.interface.flush();

    var stdin_buffer: [256]u8 = undefined;
    var stdin = std.fs.File.stdin().reader(&stdin_buffer);
    const input = stdin.interface.takeDelimiterExclusive('\n') catch |err| switch (err) {
        error.EndOfStream => return 1,
        else => return err,
    };
    log.debugAt(@src(), "Input: {s}", .{input});

    const parsed_input = if (input.len == 0) blk: {
        log.info("No input, defaulting to 0", .{});
        break :blk 0;
    } else try std.fmt.parseInt(usize, input, 10);

    if (parsed_input >= entries.len) {
        log.err("Invalid selection: {d}", .{parsed_input});
        return 1;
    }

    const to_restore = &entries[parsed_input];
    log.debugAt(@src(), "Restoring snapshot: {s}", .{to_restore.name});
    log.debugAt(@src(), "realpath: {s}", .{realpath});

    // pub fn copyFile(
    //     source_dir: Dir,
    //     source_path: []const u8,
    //     dest_dir: Dir,
    //     dest_path: []const u8,
    //     options: CopyFileOptions,
    // ) CopyFileError!void {
    //     var file_reader: File.Reader = .init(try source_dir.openFile(source_path, .{}), &.{});
    //     defer file_reader.file.close();

    //     const mode = options.override_mode orelse blk: {
    //         const st = try file_reader.file.stat();
    //         file_reader.size = st.size;
    //         break :blk st.mode;
    //     };

    //     var buffer: [1024]u8 = undefined; // Used only when direct fd-to-fd is not available.
    //     var atomic_file = try dest_dir.atomicFile(dest_path, .{
    //         .mode = mode,
    //         .write_buffer = &buffer,
    //     });
    //     defer atomic_file.deinit();

    //     _ = atomic_file.file_writer.interface.sendFileAll(&file_reader, .unlimited) catch |err| switch (err) {
    //         error.ReadFailed => return file_reader.err.?,
    //         error.WriteFailed => return atomic_file.file_writer.err.?,
    //     };

    //     try atomic_file.finish();
    // }

    const snapshot_dirname = try std.fs.path.join(allocator, &.{ dataset.mountpoint, ".zfs", "snapshot" });
    defer allocator.free(snapshot_dirname);
    var snapshot_dir = try std.fs.cwd().openDir(snapshot_dirname, .{ .iterate = true });
    defer snapshot_dir.close();

    const realpath_debug = try std.fmt.allocPrint(allocator, "{s}-debug", .{realpath});
    defer allocator.free(realpath_debug);
    log.debugAt(@src(), "realpath_debug: {s}", .{realpath_debug});

    // try std.fs.Dir.copyFile(
    //     snapshot_dir,
    //     to_restore.path, // TODO: then do we need file in SnapshotEntry?
    //     std.fs.cwd(),
    //     realpath_debug,
    //     .{},
    // );

    return 0;
}
