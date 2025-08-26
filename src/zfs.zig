const std = @import("std");
const log = @import("log.zig").axe;

pub const Dataset = struct {
    filesystem: []const u8,
    mountpoint: []const u8,

    pub fn deinit(self: Dataset, allocator: std.mem.Allocator) void {
        allocator.free(self.filesystem);
        allocator.free(self.mountpoint);
    }
};

const ZfsMountOutput = struct {
    output_version: struct {
        command: []const u8,
        vers_major: u32,
        vers_minor: u32,
    },
    datasets: std.json.ArrayHashMap(Dataset),
};

fn runCommand(allocator: std.mem.Allocator) ![]const u8 {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "zfs", "mount", "--json" },
    });
    errdefer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    log.debugAt(@src(), "stdout: {s}", .{result.stdout});
    log.debugAt(@src(), "stderr: {s}", .{result.stderr});

    switch (result.term) {
        .Exited => |code| {
            if (code != 0) {
                log.err("Command exited with non-zero code: {}", .{code});
                return error.CommandFailed;
            }
        },
        .Signal => |signal| {
            log.err("Command was terminated by signal: {}", .{signal});
            return error.CommandFailed;
        },
        else => {
            log.err("Command terminated unexpectedly: {}", .{result.term});
            return error.CommandFailed;
        },
    }

    return result.stdout;
}

pub fn findDataset(allocator: std.mem.Allocator, path: []const u8) !Dataset {
    const zfs_output = try runCommand(allocator);
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
    var best_match: ?*const Dataset = null;
    for (datasets) |*dataset| {
        if (std.mem.startsWith(u8, path, dataset.mountpoint)) {
            if (best_match == null or dataset.mountpoint.len > best_match.?.mountpoint.len) {
                best_match = dataset;
            }
        }
    }
    if (best_match == null) {
        log.err("No matching dataset found for: {s}", .{path});
        return error.NoMatchFound;
    }

    const dataset = best_match.?;
    log.debugAt(@src(), "Best match for '{s}': {s} mounted at {s}", .{
        path,
        dataset.filesystem,
        dataset.mountpoint,
    });

    return .{
        .filesystem = try allocator.dupe(u8, dataset.filesystem),
        .mountpoint = try allocator.dupe(u8, dataset.mountpoint),
    };
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
