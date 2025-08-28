const std = @import("std");
const sizeify = @import("sizeify");
const utils = @import("utils.zig");
const log = utils.log;

const max_file_size_for_hash = 10 * 1024 * 1024; // 10 MB

pub const Snapshots = struct {
    map: std.StringArrayHashMapUnmanaged(Entry) = .empty,

    pub const Entry = struct {
        name: []const u8,
        path: []const u8,
        size: u64,
        mtime: i128,
        kind: std.fs.File.Kind,

        pub fn deinit(self: Entry, allocator: std.mem.Allocator) void {
            allocator.free(self.name);
            allocator.free(self.path);
        }
    };

    pub fn deinit(self: *Snapshots, allocator: std.mem.Allocator) void {
        for (self.entries()) |entry| {
            entry.deinit(allocator);
        }
        self.map.deinit(allocator);
    }

    pub fn entries(self: Snapshots) []Entry {
        return self.map.values();
    }

    pub fn newestFirst(_: void, lhs: Entry, rhs: Entry) bool {
        return lhs.mtime > rhs.mtime;
    }

    pub fn oldestFirst(_: void, lhs: Entry, rhs: Entry) bool {
        return lhs.mtime < rhs.mtime;
    }
};

const ZfsMountOutput = struct {
    output_version: struct {
        command: []const u8,
        vers_major: u32,
        vers_minor: u32,
    },
    datasets: std.json.ArrayHashMap(Dataset),

    const Dataset = struct {
        filesystem: []const u8,
        mountpoint: []const u8,
    };
};

fn runZfsMount(allocator: std.mem.Allocator) ![]const u8 {
    const argv = [_][]const u8{ "zfs", "mount", "--json" };
    const result = try std.process.Child.run(.{ .allocator = allocator, .argv = &argv });
    errdefer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    log.debugAt(@src(), "stdout: {s}", .{result.stdout});
    log.debugAt(@src(), "stderr: {s}", .{result.stderr});

    try utils.handleTerm(&argv, result.term);

    return result.stdout;
}

pub fn findMountpoint(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const zfs_output = try runZfsMount(allocator);
    defer allocator.free(zfs_output);

    const parsed = try std.json.parseFromSlice(ZfsMountOutput, allocator, zfs_output, .{});
    defer parsed.deinit();
    const datasets = parsed.value.datasets.map.values();

    log.debugAt(@src(), "Found {d} datasets with {s} v{d}.{d}", .{
        datasets.len,
        parsed.value.output_version.command,
        parsed.value.output_version.vers_major,
        parsed.value.output_version.vers_minor,
    });
    for (datasets) |dataset| {
        log.debugAt(@src(), "Dataset: {s} mounted at {s}", .{ dataset.filesystem, dataset.mountpoint });
    }

    // find the dataset with the longest matching mountpoint prefix
    var best_match: ?*const ZfsMountOutput.Dataset = null;
    for (datasets) |*dataset| {
        if (std.mem.startsWith(u8, path, dataset.mountpoint)) {
            if (best_match == null or dataset.mountpoint.len > best_match.?.mountpoint.len) {
                best_match = dataset;
            }
        }
    }
    if (best_match) |dataset| {
        log.debugAt(@src(), "Best match for '{s}': {s} mounted at {s}", .{
            path,
            dataset.filesystem,
            dataset.mountpoint,
        });
        return allocator.dupe(u8, dataset.mountpoint);
    } else {
        log.err("No matching dataset found for: {s}", .{path});
        return error.NoMatchFound;
    }
}

pub fn getSnapshots(
    allocator: std.mem.Allocator,
    relative_path: []const u8,
    snapshot_dirname: []const u8,
    snapshot_dir: std.fs.Dir,
) !Snapshots {
    var snapshots: Snapshots = .{};
    errdefer snapshots.deinit(allocator);

    const flags: std.posix.O = .{
        .ACCMODE = .RDONLY,
        .NOFOLLOW = true, // do not follow symlinks
        .PATH = true, // record only the target path in the opened descriptor
        .CLOEXEC = true, // automatically close file on execve(2)
        .NOCTTY = true, // do not assign a controlling terminal
    };
    log.debugAt(@src(), "flags: {}", .{flags});

    var iter = snapshot_dir.iterate();
    var total_snapshots: usize = 0;
    var duplicate_entries: usize = 0;
    while (try iter.next()) |entry| : (total_snapshots += 1) {
        if (entry.kind != .directory) {
            log.warn("Skipping non-directory entry in '{s}': {s}", .{ snapshot_dirname, entry.name });
            continue;
        }

        const path = try std.fs.path.join(allocator, &.{ entry.name, relative_path });
        errdefer allocator.free(path);
        const fd = std.posix.openat(snapshot_dir.fd, path, flags, 0) catch |err| switch (err) {
            error.FileNotFound => {
                allocator.free(path);
                continue;
            },
            else => return err,
        };
        defer std.posix.close(fd);

        const stat = try std.fs.File.stat(.{ .handle = fd });
        const gop = gop: switch (stat.kind) {
            .file => if (stat.size <= max_file_size_for_hash) {
                const file = try snapshot_dir.openFile(path, .{});
                defer file.close();
                const hash = try utils.computeFileHash(file);
                // log.debugAt(@src(), "{s}\t{s}", .{ std.fmt.bytesToHex(&hash, .lower), entry.name });
                break :gop try snapshots.map.getOrPut(allocator, &hash);
            } else {
                break :gop try snapshots.map.getOrPut(allocator, entry.name);
            },
            .sym_link => {
                // TODO: readlink to get target and use it as key
                break :gop try snapshots.map.getOrPut(allocator, entry.name);
            },
            .directory => {
                // TODO: compute directory size?
                break :gop try snapshots.map.getOrPut(allocator, entry.name);
            },
            else => {
                log.warn("Skipping unsupported entry: {s} (kind: {})", .{ entry.name, stat.kind });
                allocator.free(path);
                continue;
            },
        };
        if (gop.found_existing) {
            allocator.free(path);
            duplicate_entries += 1;
        } else {
            gop.value_ptr.* = .{
                .name = try allocator.dupe(u8, entry.name),
                .path = path,
                .size = stat.size,
                .mtime = stat.mtime,
                .kind = stat.kind,
            };
        }
    }

    log.debugAt(@src(), "Found {d}/{d} valid snapshots with {d} duplicate entries", .{
        snapshots.map.count(),
        total_snapshots,
        duplicate_entries,
    });

    std.mem.sort(Snapshots.Entry, snapshots.entries(), {}, Snapshots.newestFirst);

    return snapshots;
}

test ZfsMountOutput {
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
