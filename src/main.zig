// TODO: not all in one file lol

const std = @import("std");
const sizeify = @import("sizeify");
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

    if (std.fs.cwd().access(filename, .{})) {
        log.warn("File {s} already exist", .{filename});
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => {
            log.err("Error accessing file {s}: {}", .{ filename, err });
            return err;
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
    const input = try stdin.interface.takeDelimiterExclusive('\n');
    std.log.debug("Input: {s}", .{input});

    const parsed_input = if (input.len == 0) blk: {
        log.info("No input, defaulting to 0", .{});
        break :blk 0;
    } else try std.fmt.parseInt(usize, input, 10);

    if (parsed_input >= entries.len) {
        log.err("Invalid selection: {d}", .{parsed_input});
        return 1;
    }

    const to_restore = &entries[parsed_input];
    log.debugAt(@src(), "Restoring snapshot: {s}", .{to_restore.path});
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

    try std.fs.Dir.copyFile(
        snapshot_dir,
        to_restore.path, // TODO: then do we need file in SnapshotEntry?
        std.fs.cwd(),
        realpath_debug,
        .{},
    );

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
