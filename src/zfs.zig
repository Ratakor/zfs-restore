const std = @import("std");
const utils = @import("utils.zig");
const log = utils.log;

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
