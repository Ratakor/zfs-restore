// TODO: not all in one file lol
// TODO: add interactive mode

const std = @import("std");
const log = @import("log.zig").axe;

pub const std_options: std.Options = .{
    .logFn = log.log,
};

const Dataset = struct {
    filesystem: []const u8,
    mountpoint: []const u8,
};

const ZfsMountOutput = struct {
    output_version: struct {
        command: []const u8,
        vers_major: u32,
        vers_minor: u32,
    },
    datasets: std.json.ArrayHashMap(Dataset),
};

pub fn main() !u8 {
    // TODO: use an arena
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try log.init(allocator, null, null);
    defer log.deinit(allocator);

    // TODO: use an arg parser
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next(); // progname

    const filename = args.next() orelse {
        log.err("Usage: zfs-restore <file>", .{});
        return 1;
    };
    log.debugAt(@src(), "Input file: {s}", .{filename});
    const realpath = blk: {
        // TODO: fix that
        // resolve .. correctly like
        // zfs-restore ../somefile with cwd /home/user
        // should resolve to /home/somefile not /home/user/../somefile
        // TODO: check & warn if file already exist
        const wd = try std.fs.cwd().realpathAlloc(allocator, ".");
        defer allocator.free(wd);
        break :blk try std.fs.path.join(allocator, &.{ wd, filename });
    };
    defer allocator.free(realpath);
    log.debugAt(@src(), "Resolved path: {s}", .{realpath});

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "zfs", "mount", "--json" },
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    log.debugAt(@src(), "stdout: {s}", .{result.stdout});
    log.debugAt(@src(), "stderr: {s}", .{result.stderr});

    switch (result.term) {
        .Exited => |code| {
            if (code != 0) {
                log.err("Command exited with non-zero code: {}", .{code});
                return 1;
            }
        },
        .Signal => |signal| {
            log.err("Command was terminated by signal: {}", .{signal});
            return 1;
        },
        else => {
            log.err("Command terminated unexpectedly", .{});
            log.debugAt(@src(), "term: {}", .{result.term});
            return 1;
        },
    }

    const parsed = try std.json.parseFromSlice(ZfsMountOutput, allocator, result.stdout, .{});
    defer parsed.deinit();

    log.debugAt(@src(), "Found {d} datasets with {s} v{d}.{d}", .{
        parsed.value.datasets.map.count(),
        parsed.value.output_version.command,
        parsed.value.output_version.vers_major,
        parsed.value.output_version.vers_minor,
    });
    for (parsed.value.datasets.map.values()) |entry| {
        log.debugAt(@src(), "Dataset: {s} mounted at {s}", .{ entry.filesystem, entry.mountpoint });
    }

    const datasets = parsed.value.datasets.map.values();

    // find the dataset with the longest matching mountpoint prefix
    var best_match: ?*const Dataset = null;
    for (datasets) |*dataset| {
        if (std.mem.startsWith(u8, realpath, dataset.mountpoint)) {
            if (best_match == null or dataset.mountpoint.len > best_match.?.mountpoint.len) {
                best_match = dataset;
            }
        }
    }
    if (best_match == null) {
        log.err("No matching dataset found for path: {s}", .{realpath});
        return 1;
    }

    const dataset = best_match.?;
    log.debugAt(@src(), "Best match: {s} mounted at {s}", .{ dataset.filesystem, dataset.mountpoint });
    const relative_path = realpath[dataset.mountpoint.len..];
    log.debugAt(@src(), "Relative path: {s}", .{relative_path});

    const snapshot_dirname = try std.fs.path.join(allocator, &.{ dataset.mountpoint, ".zfs", "snapshot" });
    defer allocator.free(snapshot_dirname);
    var snapshot_dir = try std.fs.cwd().openDir(snapshot_dirname, .{ .iterate = true });
    defer snapshot_dir.close();

    // TODO: expecting format 'zfs-auto-snap_FREQUENCY-YYYY-MM-DD-HHhMM'
    const SnapshotEntry = struct {
        name: []const u8,
        datetime: u64, // YYYYMMDDHHMM
    };

    var entries: std.ArrayList(SnapshotEntry) = .empty;
    defer {
        for (entries.items) |entry| {
            allocator.free(entry.name);
        }
        entries.deinit(allocator);
    }

    var iter = snapshot_dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) {
            log.warn("Skipping non-directory entry in snapshot dir: '{s}'", .{entry.name});
            continue;
        }
        // parse datetime from name
        var parts = std.mem.tokenizeScalar(u8, entry.name, '-');
        _ = parts.next(); // zfs
        _ = parts.next(); // auto
        _ = parts.next(); // snap_FREQUENCY
        const year = try std.fmt.parseInt(u64, parts.next().?, 10);
        const month = try std.fmt.parseInt(u64, parts.next().?, 10);
        const day = try std.fmt.parseInt(u64, parts.next().?, 10);
        const hour_min = parts.next().?;
        const hour = try std.fmt.parseInt(u64, hour_min[0..2], 10);
        const min = try std.fmt.parseInt(u64, hour_min[3..5], 10);
        std.debug.assert(parts.next() == null);

        // convert to a comparable integer YYYYMMDDHHMM
        const datetime = year * 100000000 + month * 1000000 + day * 10000 + hour * 100 + min * 1;

        try entries.append(allocator, .{
            .name = try allocator.dupe(u8, entry.name),
            .datetime = datetime,
        });
    }

    std.mem.sort(SnapshotEntry, entries.items, {}, struct {
        fn lessThan(_: void, lhs: SnapshotEntry, rhs: SnapshotEntry) bool {
            return lhs.datetime > rhs.datetime;
        }
    }.lessThan);

    for (entries.items) |entry| {
        log.debugAt(@src(), "Sorted snapshot: {s} -> {d}", .{ entry.name, entry.datetime });
    }

    // try to find the first snapshot that contains the relative path
    const snap_path, const snap_file = for (entries.items) |entry| {
        const snapshot_path = try std.fs.path.join(allocator, &.{ snapshot_dirname, entry.name, relative_path });
        defer allocator.free(snapshot_path);
        log.debugAt(@src(), "Checking snapshot path: {s}", .{snapshot_path});
        const file = std.fs.cwd().openFile(snapshot_path, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => {
                log.err("Error checking snapshot path '{s}': {}", .{ snapshot_path, err });
                return err;
            },
        };
        break .{ entry.name, file };
    } else {
        log.err("No snapshot found containing path: '{s}'", .{realpath});
        return 1;
    };
    defer snap_file.close();

    log.debugAt(@src(), "Found snapshot in '{s}'", .{snap_path});

    // TODO: ask to restore

    return 0;
}

test {
    const allocator = std.testing.allocator;
    const json_text =
        \\{
        \\  "output_version": {
        \\    "command": "zfs mount",
        \\    "vers_major": 0,
        \\    "vers_minor": 1
        \\  },
        \\  "datasets": {
        \\    "zpool/root": {
        \\      "filesystem": "zpool/root",
        \\      "mountpoint": "/"
        \\    },
        \\    "zpool/var": {
        \\      "filesystem": "zpool/var",
        \\      "mountpoint": "/var"
        \\    },
        \\    "zpool/nix": {
        \\      "filesystem": "zpool/nix",
        \\      "mountpoint": "/nix/store"
        \\    },
        \\    "zpool/home": {
        \\      "filesystem": "zpool/home",
        \\      "mountpoint": "/home"
        \\    }
        \\  }
        \\}
    ;

    const parsed = try std.json.parseFromSlice(ZfsMountOutput, allocator, json_text, .{});
    defer parsed.deinit();

    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    try writer.writer.print("{f}", .{std.json.fmt(parsed.value, .{ .whitespace = .indent_2 })});

    try std.testing.expectEqualStrings(json_text, writer.written());
}
