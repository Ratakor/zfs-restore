// TODO: not all in one file lol
// TODO: add interactive mode

const std = @import("std");
pub const axe = @import("axe").Axe(.{
    .mutex = .{ .function = .progress_stderr },
});

pub const std_options: std.Options = .{
    .logFn = axe.log,
};

const FstabEntry = struct {
    filesystem: []const u8,
    mountpoint: []const u8,
    type: []const u8,
    options: []const u8,
    dump: u8,
    pass: u8,

    pub fn deinit(self: FstabEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.filesystem);
        allocator.free(self.mountpoint);
        allocator.free(self.type);
        allocator.free(self.options);
    }
};

fn parseFstab(allocator: std.mem.Allocator) !std.ArrayList(FstabEntry) {
    const fstab_path = "/etc/fstab";
    const fstab_file = try std.fs.cwd().openFile(fstab_path, .{});
    defer fstab_file.close();

    var buffer: [4096]u8 = undefined;
    var reader = fstab_file.reader(&buffer);

    var entries: std.ArrayList(FstabEntry) = .empty;

    while (true) {
        const _line = reader.interface.takeDelimiterExclusive('\n') catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };

        const end = std.mem.indexOfScalar(u8, _line, '#') orelse _line.len;
        const line = _line[0..end];

        if (line.len == 0) continue;

        var fields = std.mem.tokenizeAny(u8, line, &std.ascii.whitespace);
        const filesystem = fields.next().?;
        const mountpoint = fields.next().?;
        const _type = fields.next().?;
        const options = fields.next().?;
        const dump = try std.fmt.parseInt(u8, fields.next() orelse "0", 10);
        const pass = try std.fmt.parseInt(u8, fields.next() orelse "0", 10);
        std.debug.assert(fields.next() == null);

        try entries.append(allocator, .{
            .filesystem = try allocator.dupe(u8, filesystem),
            .mountpoint = try allocator.dupe(u8, mountpoint),
            .type = try allocator.dupe(u8, _type),
            .options = try allocator.dupe(u8, options),
            .dump = dump,
            .pass = pass,
        });
    }

    // for (entries.items) |entry| {
    //     std.log.debug("Fstab Entry: {s} {s} {s} {s} {d} {d}", .{
    //         entry.filesystem,
    //         entry.mountpoint,
    //         entry.type,
    //         entry.options,
    //         entry.dump,
    //         entry.pass,
    //     });
    // }

    return entries;
}

pub fn main() !u8 {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try axe.init(allocator, null, null);
    defer axe.deinit(allocator);

    // TODO: use an arg parser
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next(); // progname

    const filename = args.next() orelse {
        std.log.err("Usage: zfs-restore <file>", .{});
        return 1;
    };
    std.log.debug("Input file: {s}", .{filename});
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
    std.log.debug("Resolved path: {s}", .{realpath});

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "zfs", "list", "-H", "-t", "filesystem", "-o", "name,mountpoint,mounted" },
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    switch (result.term) {
        .Exited => |code| {
            if (code != 0) {
                std.log.err("Command exited with non-zero code: {}", .{code});
                std.log.debug("stdout:\n{s}", .{result.stdout});
                std.log.debug("stderr:\n{s}", .{result.stderr});
                return 1;
            }
        },
        .Signal => |signal| {
            std.log.err("Command was terminated by signal: {}", .{signal});
            std.log.debug("stdout:\n{s}", .{result.stdout});
            std.log.debug("stderr:\n{s}", .{result.stderr});
            return 1;
        },
        else => {
            std.log.err("Command terminated unexpectedly", .{});
            std.log.debug("stdout:\n{s}", .{result.stdout});
            std.log.debug("stderr:\n{s}", .{result.stderr});
            std.log.debug("term: {}", .{result.term});
            return 1;
        },
    }

    std.log.debug("stdout:\n{s}", .{result.stdout});
    std.log.debug("stderr:\n{s}", .{result.stderr});

    var fstab = try parseFstab(allocator);
    defer {
        for (fstab.items) |entry| {
            entry.deinit(allocator);
        }
        fstab.deinit(allocator);
    }

    const Filesystem = struct {
        name: []const u8,
        mountpoint: []const u8,
    };

    var datasets: std.ArrayList(Filesystem) = .empty;
    defer {
        for (datasets.items) |dataset| {
            allocator.free(dataset.name);
            allocator.free(dataset.mountpoint);
        }
        datasets.deinit(allocator);
    }

    var it = std.mem.tokenizeScalar(u8, result.stdout, '\n');
    while (it.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, &std.ascii.whitespace);
        const name = fields.next().?;
        const mountpoint = fields.next().?;
        const mounted = fields.next().?;

        if (std.mem.eql(u8, mounted, "yes")) {
            if (std.mem.eql(u8, mountpoint, "legacy")) {
                // find mountpoint via /etc/fstab
                for (fstab.items) |entry| {
                    if (std.mem.eql(u8, entry.filesystem, name)) {
                        try datasets.append(allocator, .{
                            .name = try allocator.dupe(u8, name),
                            .mountpoint = try allocator.dupe(u8, entry.mountpoint),
                        });
                        break;
                    }
                }
            } else {
                try datasets.append(allocator, .{
                    .name = try allocator.dupe(u8, name),
                    .mountpoint = try allocator.dupe(u8, mountpoint),
                });
            }
        }

        std.debug.assert(fields.next() == null);
    }

    for (datasets.items) |dataset| {
        std.log.debug("Filesystem: {s}, Mountpoint: {s}", .{ dataset.name, dataset.mountpoint });
    }

    // find the dataset with the longest matching mountpoint prefix
    var best_match: ?*const Filesystem = null;
    for (datasets.items) |*dataset| {
        if (std.mem.startsWith(u8, realpath, dataset.mountpoint)) {
            if (best_match == null or dataset.mountpoint.len > best_match.?.mountpoint.len) {
                best_match = dataset;
            }
        }
    }
    if (best_match == null) {
        std.log.err("No matching dataset found for path: {s}", .{realpath});
        return 1;
    }

    const dataset = best_match.?;
    std.log.debug("Best match: {s} mounted at {s}", .{ dataset.name, dataset.mountpoint });
    const relative_path = realpath[dataset.mountpoint.len..];
    std.log.debug("Relative path: {s}", .{relative_path});

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
            std.log.warn("Skipping non-directory entry in snapshot dir: '{s}'", .{entry.name});
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
        std.log.debug("Sorted snapshot: {s} -> {d}", .{ entry.name, entry.datetime });
    }

    // try to find the first snapshot that contains the relative path
    const snap_path, const snap_file = for (entries.items) |entry| {
        const snapshot_path = try std.fs.path.join(allocator, &.{ snapshot_dirname, entry.name, relative_path });
        defer allocator.free(snapshot_path);
        std.log.debug("Checking snapshot path: {s}", .{snapshot_path});
        const file = std.fs.cwd().openFile(snapshot_path, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => {
                std.log.err("Error checking snapshot path '{s}': {}", .{ snapshot_path, err });
                return err;
            },
        };
        break .{ entry.name, file };
    } else {
        std.log.err("No snapshot found containing path: '{s}'", .{realpath});
        return 1;
    };
    defer snap_file.close();

    std.log.debug("Found snapshot in '{s}'", .{snap_path});

    // TODO: ask to restore

    return 0;
}
