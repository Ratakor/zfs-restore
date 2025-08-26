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
        if (std.fs.path.isAbsolute(filename)) {
            break :blk try allocator.dupe(u8, filename);
        }
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
    var snapshots = try snap.getSnapshots(allocator, dataset.mountpoint, realpath);
    defer snapshots.deinit(allocator);
    const entries = snapshots.entries();

    if (entries.len == 0) {
        log.info("No snapshots found for file: {s}", .{realpath});
        return 0;
    }

    std.mem.sort(snap.SnapshotEntry, entries, {}, snap.SnapshotEntry.newestFirst);

    log.debugAt(@src(), "first entry: {s}", .{entries[0].name});

    // ask to restore
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buffer);

    // TODO: if entries.len == 1 ask a y/N question instead?
    // TODO: add a way to see the files before restoring?
    var it = std.mem.reverseIterator(entries);
    while (it.next()) |entry| {
        try stdout.interface.print("{d: >4} {s} ({f})\n", .{
            it.index,
            entry.name,
            // TODO: entry.mtime, make it look like eza with a header (& colors)?
            sizeify.fmt(entry.size, .decimal_short),
        });
    }
    try stdout.interface.print("Which version to restore [0..{d}]: ", .{entries.len - 1});
    try stdout.interface.flush();

    var stdin_buffer: [256]u8 = undefined;
    var stdin = std.fs.File.stdin().reader(&stdin_buffer);
    const input = try stdin.interface.takeDelimiterExclusive('\n');
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

    const snapshot_dirname = try std.fs.path.join(allocator, &.{ dataset.mountpoint, ".zfs", "snapshot" });
    defer allocator.free(snapshot_dirname);
    var snapshot_dir = try std.fs.cwd().openDir(snapshot_dirname, .{ .iterate = true });
    defer snapshot_dir.close();

    const wd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(wd);
    log.debugAt(@src(), "{s}/{s} -> {s}/{s}", .{ snapshot_dirname, to_restore.path, wd, filename });

    // try std.fs.Dir.copyFile(
    //     snapshot_dir,
    //     to_restore.path,
    //     std.fs.cwd(),
    //     filename,
    //     .{},
    // );

    return 0;
}
