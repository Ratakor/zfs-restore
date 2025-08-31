// https://github.com/jiacai2050/zigcli/blob/main/src/mod/pretty-table.zig
// Modifications under the same license as the rest of the zfs-restore project.
//
// MIT License
//
// Copyright (c) Jiacai Liu <dev@liujiacai.net>
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

const std = @import("std");

pub const String = []const u8;
pub const Col = struct {
    string: String,
    color: ?std.Io.tty.Color = null,
};
pub fn Row(comptime num: usize) type {
    return [num]Col;
}

pub const Separator = struct {
    pub const Mode = enum {
        ascii,
        box,
        dos,
        round,
        spaced_ascii,
        spaced_box,
        spaced_dos,
        spaced_round,
    };

    const box = [_][4]String{
        .{ "┌", "─", "┬", "┐" },
        .{ "│", "─", "│", "│" },
        .{ "├", "─", "┼", "┤" },
        .{ "└", "─", "┴", "┘" },
    };

    const spaced_box = [_][4]String{
        .{ "┌─", "─", "─┬─", "─┐" },
        .{ "│ ", "─", " │ ", " │" },
        .{ "├─", "─", "─┼─", "─┤" },
        .{ "└─", "─", "─┴─", "─┘" },
    };

    const round = [_][4]String{
        .{ "╭", "─", "┬", "╮" },
        .{ "│", "─", "│", "│" },
        .{ "├", "─", "┼", "┤" },
        .{ "╰", "─", "┴", "╯" },
    };

    const spaced_round = [_][4]String{
        .{ "╭─", "─", "─┬─", "─╮" },
        .{ "│ ", "─", " │ ", " │" },
        .{ "├─", "─", "─┼─", "─┤" },
        .{ "╰─", "─", "─┴─", "─╯" },
    };

    const ascii = [_][4]String{
        .{ "+", "-", "+", "+" },
        .{ "|", "-", "|", "|" },
        .{ "+", "-", "+", "+" },
        .{ "+", "-", "+", "+" },
    };

    const spaced_ascii = [_][4]String{
        .{ "+-", "-", "-+-", "-+" },
        .{ "| ", "-", " | ", " |" },
        .{ "+-", "-", "-+-", "-+" },
        .{ "+-", "-", "-+-", "-+" },
    };

    const dos = [_][4]String{
        .{ "╔", "═", "╦", "╗" },
        .{ "║", "═", "║", "║" },
        .{ "╠", "═", "╬", "╣" },
        .{ "╚", "═", "╩", "╝" },
    };

    const spaced_dos = [_][4]String{
        .{ "╔═", "═", "═╦═", "═╗" },
        .{ "║ ", "═", " ║ ", " ║" },
        .{ "╠═", "═", "═╬═", "═╣" },
        .{ "╚═", "═", "═╩═", "═╝" },
    };

    const Position = enum { First, Text, Sep, Last };

    fn get(mode: Mode, row_pos: Position, col_pos: Position) []const u8 {
        const sep_table = switch (mode) {
            .ascii => ascii,
            .box => box,
            .dos => dos,
            .round => round,
            .spaced_ascii => spaced_ascii,
            .spaced_box => spaced_box,
            .spaced_dos => spaced_dos,
            .spaced_round => spaced_round,
        };

        return sep_table[@intFromEnum(row_pos)][@intFromEnum(col_pos)];
    }
};

pub fn Table(comptime len: usize) type {
    return struct {
        header: ?Row(len) = null,
        footer: ?Row(len) = null,
        rows: []const Row(len),
        mode: Separator.Mode = .ascii,
        padding: usize = 0,
        tty_config: std.Io.tty.Config = .no_color,

        const Self = @This();

        fn writeRowDelimiter(self: Self, writer: *std.Io.Writer, row_pos: Separator.Position, col_lens: [len]usize) !void {
            inline for (0..len, col_lens) |col_idx, max_len| {
                const first_col = col_idx == 0;
                if (first_col) {
                    try writer.writeAll(Separator.get(self.mode, row_pos, .First));
                } else {
                    try writer.writeAll(Separator.get(self.mode, row_pos, .Sep));
                }

                for (0..max_len) |_| {
                    try writer.writeAll(Separator.get(self.mode, row_pos, .Text));
                }
            }

            try writer.writeAll(Separator.get(self.mode, row_pos, .Last));
            try writer.writeAll("\n");
        }

        fn writeRow(
            self: Self,
            writer: *std.io.Writer,
            row: []const Col,
            col_lens: [len]usize,
        ) !void {
            const m = self.mode;
            for (row, col_lens, 0..) |column, col_len, col_idx| {
                const first_col = col_idx == 0;
                if (first_col) {
                    try writer.writeAll(Separator.get(m, .Text, .First));
                } else {
                    try writer.writeAll(Separator.get(m, .Text, .Sep));
                }

                if (column.color) |c| {
                    try self.setColor(writer, c);
                    try writer.writeAll(column.string);
                    try self.setColor(writer, .reset);
                } else {
                    try writer.writeAll(column.string);
                }

                const left: usize = col_len - column.string.len;
                for (0..left) |_| {
                    try writer.writeAll(" ");
                }
            }
            try writer.writeAll(Separator.get(m, .Text, .Last));
            try writer.writeAll("\n");
        }

        fn calculateColumnLens(self: Self) [len]usize {
            var lens = std.mem.zeroes([len]usize);
            if (self.header) |header| {
                for (header, &lens) |column, *n| {
                    n.* = column.string.len;
                }
            }

            for (self.rows) |row| {
                for (row, &lens) |col, *n| {
                    n.* = @max(col.string.len, n.*);
                }
            }

            if (self.footer) |footer| {
                for (footer, &lens) |col, *n| {
                    n.* = @max(col.string.len, n.*);
                }
            }

            for (&lens) |*n| {
                n.* += self.padding;
            }
            return lens;
        }

        fn setColor(self: Self, writer: *std.Io.Writer, color: std.Io.tty.Color) std.Io.Writer.Error!void {
            self.tty_config.setColor(writer, color) catch return std.Io.Writer.Error.WriteFailed;
        }

        pub fn format(
            self: Self,
            writer: *std.Io.Writer,
        ) !void {
            const column_lens = self.calculateColumnLens();

            try self.writeRowDelimiter(writer, .First, column_lens);
            if (self.header) |header| {
                try self.writeRow(
                    writer,
                    &header,
                    column_lens,
                );
            }

            try self.writeRowDelimiter(writer, .Sep, column_lens);
            for (self.rows) |row| {
                try self.writeRow(writer, &row, column_lens);
            }

            if (self.footer) |footer| {
                try self.writeRowDelimiter(writer, .Sep, column_lens);
                try self.writeRow(writer, &footer, column_lens);
            }

            try self.writeRowDelimiter(writer, .Last, column_lens);
        }
    };
}

test "normal usage" {
    const t = Table(2){
        .header = [_]String{ "Version", "Date" },
        .rows = &[_][2]String{
            .{ "0.7.1", "2020-12-13" },
            .{ "0.7.0", "2020-11-08" },
            .{ "0.6.0", "2020-04-13" },
            .{ "0.5.0", "2019-09-30" },
        },
        .footer = null,
    };

    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    try out.writer().print("{}", .{t});

    try std.testing.expectEqualStrings(
        \\+-------+----------+
        \\|Version|Date      |
        \\+-------+----------+
        \\|0.7.1  |2020-12-13|
        \\|0.7.0  |2020-11-08|
        \\|0.6.0  |2020-04-13|
        \\|0.5.0  |2019-09-30|
        \\+-------+----------+
        \\
    , out.items);
}

test "footer usage" {
    const t = Table(2){
        .header = [_]String{ "Language", "Files" },
        .rows = &[_][2]String{
            .{ "Zig", "3" },
            .{ "Python", "2" },
        },
        .footer = [2]String{ "Total", "5" },
    };

    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    try out.writer().print("{}", .{t});

    try std.testing.expectEqualStrings(
        \\+--------+-----+
        \\|Language|Files|
        \\+--------+-----+
        \\|Zig     |3    |
        \\|Python  |2    |
        \\+--------+-----+
        \\|Total   |5    |
        \\+--------+-----+
        \\
    , out.items);
}
