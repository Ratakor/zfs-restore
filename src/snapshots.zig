const std = @import("std");
const log = @import("log.zig").axe;
const Sha256 = std.crypto.hash.sha2.Sha256;

// TODO: handle restoring directories

pub const SnapshotEntry = struct {
    name: []const u8,
    path: []const u8,
    file: std.fs.File,
    size: u64,
    mtime: i128,

    pub fn deinit(self: SnapshotEntry, allocator: std.mem.Allocator) void {
        self.file.close();
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

pub fn getEntries(
    allocator: std.mem.Allocator,
    mountpoint: []const u8,
    realpath: []const u8,
) ![]SnapshotEntry {
    const relative_path = realpath[mountpoint.len..];
    log.debugAt(@src(), "relative_path: {s}", .{relative_path});
    const snapshot_dirname = try std.fs.path.join(allocator, &.{ mountpoint, ".zfs", "snapshot" });
    defer allocator.free(snapshot_dirname);
    log.debugAt(@src(), "snapshot_dirname: {s}", .{snapshot_dirname});
    var snapshot_dir = try std.fs.cwd().openDir(snapshot_dirname, .{ .iterate = true });
    defer snapshot_dir.close();

    var map: std.StringArrayHashMapUnmanaged(SnapshotEntry) = .empty;
    errdefer {
        for (map.values()) |entry| {
            entry.deinit(allocator);
        }
        map.deinit(allocator);
    }

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
        const file = snapshot_dir.openFile(path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                allocator.free(path);
                continue;
            },
            else => {
                log.err("Error checking snapshot path '{s}/{s}': {t}", .{
                    snapshot_dirname,
                    path,
                    err,
                });
                return err;
            },
        };
        errdefer file.close();

        const hash = try computeHash(file);
        // log.debugAt(@src(), "hash: {s}", .{std.fmt.bytesToHex(&hash, .lower)});
        const gop = try map.getOrPut(allocator, &hash);
        if (gop.found_existing) {
            file.close();
            allocator.free(path);
            duplicate_entries += 1;
        } else {
            const stat = try file.stat();
            gop.value_ptr.* = .{
                .name = try allocator.dupe(u8, entry.name),
                .file = file,
                .path = path,
                .size = stat.size,
                .mtime = stat.mtime,
            };
        }
    }

    log.debugAt(@src(), "Found {d}/{d} valid snapshots with {d} duplicate entries", .{
        map.count(),
        total_snapshots,
        duplicate_entries,
    });

    // I don't know how to do otherwise
    const values = try allocator.dupe(SnapshotEntry, map.values());
    map.deinit(allocator);
    return values;
}
