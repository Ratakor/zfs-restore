const std = @import("std");
const clap = @import("clap");
const sizeify = @import("sizeify");
const zeit = @import("zeit");
const pretty_table = @import("pretty_table.zig");
const utils = @import("utils.zig");
const log = utils.log;
const zfs = @import("zfs.zig");

pub const std_options: std.Options = .{
    .logFn = log.log,
};

// based on clap.Diagnostic.report
fn reportBadArg(diag: clap.Diagnostic, err: anyerror) void {
    var longest = diag.name.longest();
    if (longest.kind == .positional) {
        longest.name = diag.arg;
    }

    switch (err) {
        clap.streaming.Error.DoesntTakeValue => log.err(
            "The argument '{s}{s}' does not take a value",
            .{ longest.kind.prefix(), longest.name },
        ),
        clap.streaming.Error.MissingValue => log.err(
            "The argument '{s}{s}' requires a value but none was supplied",
            .{ longest.kind.prefix(), longest.name },
        ),
        clap.streaming.Error.InvalidArgument => log.err(
            "Invalid argument '{s}{s}'",
            .{ longest.kind.prefix(), longest.name },
        ),
        else => log.err("Error while parsing arguments: {t}", .{err}),
    }
}

fn usage(comptime params: []const clap.Param(clap.Help)) !void {
    var buffer: [256]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&buffer);
    const stderr = &stderr_writer.interface;

    try stderr.writeAll("Usage: zfs-restore ");
    try clap.usage(stderr, clap.Help, params);
    try stderr.writeAll("\n\nOptions:\n");
    try clap.help(stderr, clap.Help, params, .{
        .description_on_new_line = false,
        .description_indent = 2,
        .spacing_between_parameters = 0,
        .indent = 2,
    });
    try stderr.flush();
}

pub fn main() !u8 {
    const cwd = std.fs.cwd();

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    try log.init(allocator, null, &env_map);
    defer log.deinit(allocator);

    const timezone = try zeit.local(allocator, &env_map);
    defer timezone.deinit();

    const params = comptime clap.parseParamsComptime(
        \\-h, --help         Display this help and exit.
        // \\-v, --version      Display version information and exit.
        // \\-i, --interactive  Interactive mode, open the file in $PAGER before restoring.
        \\<path>
        \\
    );

    const parsers = comptime .{
        .path = clap.parsers.string,
    };

    var diag: clap.Diagnostic = .{};
    var res = clap.parse(clap.Help, &params, parsers, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        reportBadArg(diag, err);
        try usage(&params);
        return 1;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        try usage(&params);
        return 0;
    }

    // TODO: interactive mode
    // - add a way to see the files before restoring
    // - add a way to see directory via $FILE_MANAGER or something
    // - add a way to see symlink target
    // const interactive = res.args.interactive != 0;

    const input_path = res.positionals[0] orelse {
        log.err("No path provided", .{});
        try usage(&params);
        return 1;
    };
    log.debugAt(@src(), "input_path: {s}", .{input_path});

    const realpath = blk: {
        if (std.fs.path.isAbsolute(input_path)) {
            break :blk try std.fs.path.resolve(allocator, &.{input_path});
        }
        // https://stackoverflow.com/questions/72709702/how-do-i-get-the-full-path-of-a-std-fs-dir
        const working_directory = try cwd.realpathAlloc(allocator, ".");
        defer allocator.free(working_directory);
        break :blk try std.fs.path.resolve(allocator, &.{ working_directory, input_path });
    };
    defer allocator.free(realpath);
    log.debugAt(@src(), "realpath: {s}", .{realpath});

    const path_already_exist = if (cwd.access(realpath, .{})) true else |err| switch (err) {
        error.FileNotFound => false,
        else => return err,
    };

    const mountpoint = try zfs.findMountpoint(allocator, realpath);
    defer allocator.free(mountpoint);

    const relative_path = realpath[mountpoint.len + 1 ..];
    log.debugAt(@src(), "relative_path: {s}", .{relative_path});
    const snapshot_dirname = try std.fs.path.join(allocator, &.{ mountpoint, ".zfs", "snapshot" });
    defer allocator.free(snapshot_dirname);
    log.debugAt(@src(), "snapshot_dirname: {s}", .{snapshot_dirname});
    var snapshot_dir = try cwd.openDir(snapshot_dirname, .{ .iterate = true });
    defer snapshot_dir.close();

    var snapshots = try zfs.getSnapshots(
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

    // ask to restore
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    // TODO: add colors
    var table: pretty_table.Table(5) = .{
        .header = .{ "Index", "Snapshot Name", "Date Modified", "Size", "Kind" },
        .rows = undefined,
        .mode = .spaced_round,
    };
    var rows: std.ArrayList([5][]const u8) = .empty;
    defer {
        for (rows.items) |row| {
            allocator.free(row[0]); // Index
            // allocator.free(row[1]); // Name
            allocator.free(row[2]); // Date Modified
            allocator.free(row[3]); // Size
            // allocator.free(row[4]); // Kind
        }
        rows.deinit(allocator);
    }

    var it = std.mem.reverseIterator(entries);
    while (it.next()) |entry| {
        const time = (try zeit.instant(.{
            .source = .{ .unix_nano = entry.mtime },
            .timezone = &timezone,
        })).time();
        var buffer: [32]u8 = undefined;
        var time_writer = std.Io.Writer.fixed(&buffer);
        try time.strftime(&time_writer, "%d %b %H:%M");

        // const size = switch (entry.kind) {
        //     .file => try sizeify.formatAlloc(entry.size, .decimal_short, allocator),
        //     .sym_link => try allocator.dupe(u8, "-"),
        //     .directory => try std.fmt.allocPrint(allocator, "{d} files", .{entry.size}),
        //     else => unreachable,
        // };

        try rows.append(allocator, .{
            try std.fmt.allocPrint(allocator, "{d: >4}", .{it.index}),
            entry.name,
            try allocator.dupe(u8, time_writer.buffered()),
            try sizeify.formatAlloc(entry.size, .decimal_short, allocator), // size,
            @tagName(entry.kind),
        });
    }
    table.rows = rows.items;
    try stdout.print("{f}", .{table});
    try stdout.print("Which version to restore [0..{d}]: ", .{entries.len - 1});
    try stdout.flush();

    var stdin_buffer: [32]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);
    const stdin = &stdin_reader.interface;
    const input = try stdin.takeDelimiterExclusive('\n');
    log.debugAt(@src(), "input: {s}", .{input});

    const parsed_input = if (input.len == 0) 0 else try std.fmt.parseInt(usize, input, 10);
    if (parsed_input >= entries.len) {
        log.err("Invalid selection: {d}", .{parsed_input});
        return 1;
    }

    const to_restore = &entries[parsed_input];
    log.debugAt(@src(), "{f} -> {s}", .{
        utils.fmt.join(&.{ snapshot_dirname, to_restore.path }, std.fs.path.sep_str),
        realpath,
    });

    // if (interactive) {
    //     const pager = env_map.get("PAGER") orelse "less";
    //     const argv = [_][]const u8{ pager, to_restore.path };
    //     log.debugAt(@src(), "Running `{f}`", .{utils.fmt.join(&argv, " ")});
    //     var child: std.process.Child = .init(&argv, allocator);
    //     child.cwd_dir = snapshot_dir;
    //     child.env_map = &env_map;
    //     try child.spawn();
    //     // errdefer _ = child.kill() catch {};
    //     const term = try child.wait();
    //     try utils.handleTerm(&argv, term);
    //     log.debugAt(@src(), "end of interactive mode, exiting...", .{});
    //     return 2;
    // }

    if (path_already_exist) {
        log.warn("'{s}' already exist", .{realpath});
        try stdout.writeAll("Overwrite? [y/N]: ");
        try stdout.flush();
        const confirm = try stdin.takeDelimiterExclusive('\n');
        log.debugAt(@src(), "confirm: {s}", .{confirm});
        if (confirm.len == 0 or !std.ascii.startsWithIgnoreCase("yes", confirm)) {
            log.info("Aborting...", .{});
            return 0;
        }
    }

    log.info("Restoring snapshot: {s}", .{to_restore.name});
    // cp ftw
    const to_restore_full_path = try std.fs.path.join(allocator, &.{ snapshot_dirname, to_restore.path });
    defer allocator.free(to_restore_full_path);
    const cp_argv = [_][]const u8{ "cp", "-a", "--", to_restore_full_path, realpath };
    log.debugAt(@src(), "Running `{f}`", .{utils.fmt.join(&cp_argv, " ")});
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &cp_argv,
        .cwd_dir = cwd,
        .env_map = &env_map,
    });
    log.debugAt(@src(), "stdout: {s}", .{result.stdout});
    log.debugAt(@src(), "stderr: {s}", .{result.stderr});
    try utils.handleTerm(&cp_argv, result.term);
    // try std.fs.Dir.copyFile(snapshot_dir, to_restore.path, cwd, realpath, .{});

    return 0;
}
