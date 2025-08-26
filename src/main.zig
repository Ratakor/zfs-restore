// TODO: not all in one file lol

const std = @import("std");
const log = @import("log.zig").axe;
const snap = @import("snapshots.zig");

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

    const entries = try snap.getEntries(allocator, dataset.mountpoint, realpath);
    defer {
        for (entries) |entry| {
            entry.deinit(allocator);
        }
        allocator.free(entries);
    }

    std.mem.sort(snap.SnapshotEntry, entries, {}, snap.SnapshotEntry.oldestFirst);

    log.debugAt(@src(), "first entry: {s}", .{entries[0].name});

    // TODO: ask to restore
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buffer);

    // TODO: check if entries.items.len == 1 and == 0
    var i: usize = entries.len;
    for (entries) |entry| {
        i -= 1;
        try stdout.interface.print("{d: >4} {s} {d}\n", .{ i, entry.name, entry.size });
    }
    try stdout.interface.print("What file to restore [0..{d}]: ", .{entries.len});
    try stdout.interface.flush();

    // var stdin = std.fs.File.stdin().reader(&.{});
    // _ = try stdin.interface.readByte();

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
