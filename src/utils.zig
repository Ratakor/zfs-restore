const std = @import("std");

// See https://github.com/Ratakor/zfs-restore/commit/fb7f63d8a739b9ee5f025288d0f36966184a47ec
// for file logging.
// The reason why I decided to not use it is because changing std_options.logFn
// is way too much footgun if using axe with time or additional writers. So I
// prefer to keep the custom std_options rather than having a probably useless
// log file.
pub const log = @import("axe").Axe(.{
    .mutex = .{ .function = .progress_stderr },
});

pub const fmt = struct {
    pub const JoinFormatter = struct {
        slices: []const []const u8,
        sep: []const u8,

        pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            if (self.slices.len == 0) return;
            try writer.writeAll(self.slices[0]);
            for (self.slices[1..]) |slice| {
                try writer.writeAll(self.sep);
                try writer.writeAll(slice);
            }
        }
    };

    pub fn join(slices: []const []const u8, sep: []const u8) JoinFormatter {
        return JoinFormatter{ .slices = slices, .sep = sep };
    }
};

pub fn handleTerm(argv: []const []const u8, term: std.process.Child.Term) !void {
    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                log.err("Command `{f}` exited with code: {d}", .{ fmt.join(argv, " "), code });
                return error.CommandFailed;
            }
        },
        else => {
            log.err("Command `{f}` terminated unexpectedly: {}", .{ fmt.join(argv, " "), term });
            return error.CommandFailed;
        },
    }
}
