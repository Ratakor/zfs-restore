const std = @import("std");
const sizeify = @import("sizeify");
const utils = @import("utils.zig");
const log = utils.log;
const Sha256 = std.crypto.hash.sha2.Sha256;

const max_file_size_for_hash = 10 * 1024 * 1024; // 10 MB

// TODO: handle restoring directories

pub const Snapshots = struct {
    map: std.StringArrayHashMapUnmanaged(SnapshotEntry) = .empty,

    pub fn deinit(self: *Snapshots, allocator: std.mem.Allocator) void {
        for (self.map.values()) |entry| {
            entry.deinit(allocator);
        }
        self.map.deinit(allocator);
    }

    pub fn entries(self: Snapshots) []SnapshotEntry {
        return self.map.values();
    }
};

pub const SnapshotEntry = struct {
    name: []const u8,
    path: []const u8,
    size: u64,
    mtime: i128,
    kind: std.fs.File.Kind,

    pub fn deinit(self: SnapshotEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.path);
    }

    pub fn newestFirst(_: void, lhs: SnapshotEntry, rhs: SnapshotEntry) bool {
        return lhs.mtime > rhs.mtime;
    }

    pub fn oldestFirst(_: void, lhs: SnapshotEntry, rhs: SnapshotEntry) bool {
        return lhs.mtime < rhs.mtime;
    }
};

fn computeHash(file: std.fs.File) ![Sha256.digest_length]u8 {
    var sha256 = Sha256.init(.{});
    var buffer: [4096]u8 = undefined;
    var n = try file.read(&buffer);
    while (n != 0) {
        sha256.update(buffer[0..n]);
        n = try file.read(&buffer);
    }
    return sha256.finalResult();
}

pub fn getSnapshots(
    allocator: std.mem.Allocator,
    relative_path: []const u8,
    snapshot_dirname: []const u8,
    snapshot_dir: std.fs.Dir,
) !Snapshots {
    var snapshots: Snapshots = .{};
    errdefer snapshots.deinit(allocator);

    var flags: std.posix.O = .{ .ACCMODE = .RDONLY };
    if (@hasField(std.posix.O, "NOFOLLOW")) flags.NOFOLLOW = true;
    if (@hasField(std.posix.O, "PATH")) flags.PATH = true;
    if (@hasField(std.posix.O, "CLOEXEC")) flags.CLOEXEC = true;
    if (@hasField(std.posix.O, "LARGEFILE")) flags.LARGEFILE = true;
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
        const file: std.fs.File = .{ .handle = fd };

        const stat = try file.stat();
        const gop = gop: switch (stat.kind) {
            .file => if (stat.size <= max_file_size_for_hash) {
                const hash = try computeHash(file);
                // log.debugAt(@src(), "{s}\t{s}", .{ std.fmt.bytesToHex(&hash, .lower), entry.name });
                break :gop try snapshots.map.getOrPut(allocator, &hash);
            } else {
                break :gop try snapshots.map.getOrPut(allocator, entry.name);
            },
            .sym_link => {
                // TODO: readlink
                break :gop try snapshots.map.getOrPut(allocator, entry.name);
            },
            .directory => {
                // TODO: compute directory size?
                break :gop try snapshots.map.getOrPut(allocator, entry.name);
            },
            else => {
                log.warn("Skipping unsupported entry in '{s}': {s} (kind: {})", .{
                    snapshot_dirname,
                    entry.name,
                    stat.kind,
                });
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

    return snapshots;
}
