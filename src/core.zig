const py = @import("pydust");
const std = @import("std");
const ffi = py.ffi;
const root = @This();

const allocator = std.heap.page_allocator;

pub const NoNewLineIterator = struct {
    data: [:0]const u8,
    index: usize = 0,

    /// Initializes an iterator
    pub fn create(data: [:0]const u8) NoNewLineIterator {
        return .{ .data = data};
    }

    /// Returns the next no new line character with its index: (absolute_index, character)
    pub fn next(self: *NoNewLineIterator) ?struct {usize, u8} {
        while (self.index < self.data.len) {
            const pos = self.index;
            const char = self.data[self.index];
            self.index += 1;
            if (char != '\n') {
                return .{pos, char};
            }
        }
        return null;
    }

    pub fn reset(self: *NoNewLineIterator) void {
        self.index = 0;
    }
};


pub fn mask(args: struct {input: py.PyBytes(root), words: py.PyTuple(root)}) !py.PyBytes(root) {
    const input_slice = try args.input.asSlice();
    var input_it = NoNewLineIterator.create(input_slice);

    var buf = try allocator.allocSentinel(u8, input_slice.len, 0);
    defer allocator.free(buf);
    @memcpy(buf, input_slice);

    for (0..args.words.length()) |pos| {
        const item = try args.words.getItem(py.PyBytes(root), pos);
        var item_it = NoNewLineIterator.create(try item.asSlice());

        var item_i: usize = undefined;
        var item_char: u8 = undefined;
        if (item_it.next()) |p| {
            item_i, item_char = p;
        } else {
            continue;
        }
        const item_start = item_i;
        const item_first_char = item_char;

        var match_start: usize = 0;
        var return_pos: usize = 0;
        while (input_it.next()) |r| {
            const i, const char = r;
            // std.debug.print("{c} . {c}\n", .{ char, item_char });
            if (char == item_char) {
                // std.debug.print("{c}={c}\n", .{ char, item_char });
                if (item_i == item_start) {
                    match_start = i;
                } else if (return_pos == 0 and char == item_first_char) {
                    return_pos = i;
                }
                if (item_it.next()) |p| {
                    item_i, item_char = p;
                } else {
                    for (buf[match_start..i + 1]) |*b| {
                        if (b.* != '\n') b.* = '*';
                    }
                    item_it.reset();
                    if (item_it.next()) |p| {
                        item_i, item_char = p;
                    }
                    return_pos = 0;
                }
            } else if (item_i > item_start) {
                // std.debug.print("{c} <> {c}\n", .{ char, item_char });
                item_it.reset();
                if (item_it.next()) |p| {
                    item_i, item_char = p;
                }
                if (return_pos == 0) {
                    input_it.index -= 1;
                } else {
                    input_it.index = return_pos;
                    return_pos = 0;
                }

            }
        }
        input_it.reset();
    }
    const res = py.PyBytes(root).create(buf);
    return res;
}

comptime {
    py.rootmodule(root);
}
