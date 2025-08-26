const std = @import("std");
const sizeify = @import("sizeify");
const utils = @import("utils.zig");
const log = utils.log;
const zfs = @import("zfs.zig");
const snap = @import("snapshots.zig");

pub const std_options: std.Options = .{
    .logFn = log.log,
};

pub fn main() !u8 {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    try log.init(allocator, null, &env_map);
    defer log.deinit(allocator);

    // TODO: use an arg parser
    ////////////////////////////////////////////////////////////////////////////

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    var interactive = false;

    _ = args.next(); // progname

    const filename = args.next() orelse {
        log.err("Usage: zfs-restore <file>", .{});
        return 1;
    };
    log.debugAt(@src(), "Input file: {s}", .{filename});

    if (args.next()) |extra| {
        if (std.mem.eql(u8, extra, "-i") or std.mem.eql(u8, extra, "--interactive")) {
            interactive = true;
        }
    }

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

    const mountpoint = try zfs.findMountpoint(allocator, realpath);
    defer allocator.free(mountpoint);

    const relative_path = realpath[mountpoint.len + 1 ..];
    log.debugAt(@src(), "relative_path: {s}", .{relative_path});
    const snapshot_dirname = try std.fs.path.join(allocator, &.{ mountpoint, ".zfs", "snapshot" });
    defer allocator.free(snapshot_dirname);
    log.debugAt(@src(), "snapshot_dirname: {s}", .{snapshot_dirname});
    var snapshot_dir = try std.fs.cwd().openDir(snapshot_dirname, .{ .iterate = true });
    defer snapshot_dir.close();

    var snapshots = try snap.getSnapshots(
        allocator,
        relative_path,
        snapshot_dirname,
        snapshot_dir,
    );
    defer snapshots.deinit(allocator);
    const entries = snapshots.entries();

    if (entries.len == 0) {
        log.err("No snapshot found for: {s}", .{realpath});
        return 1;
    }

    std.mem.sort(snap.SnapshotEntry, entries, {}, snap.SnapshotEntry.newestFirst);

    log.debugAt(@src(), "first entry: {s}", .{entries[0].name});

    // ask to restore
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buffer);

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

    const wd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(wd);
    log.debugAt(@src(), "{s}/{s} -> {s}/{s}", .{ snapshot_dirname, to_restore.path, wd, filename });

    if (interactive) {
        const pager = env_map.get("PAGER") orelse "less";
        const argv = [_][]const u8{ pager, to_restore.path };
        log.debugAt(@src(), "Running `{f}`", .{utils.fmt.join(&argv, " ")});
        var child: std.process.Child = .init(&argv, allocator);
        child.cwd_dir = snapshot_dir;
        child.env_map = &env_map;
        try child.spawn();
        // errdefer _ = child.kill() catch {};
        const term = try child.wait();
        try utils.handleTerm(&argv, term);
        log.debugAt(@src(), "TODO: end of interactive mode, exiting...", .{});
        return 2;
    }

    // try std.fs.Dir.copyFile(
    //     snapshot_dir,
    //     to_restore.path,
    //     std.fs.cwd(),
    //     filename,
    //     .{},
    // );

    return 0;
}
