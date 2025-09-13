const py = @import("pydust");
const std = @import("std");
const ffi = py.ffi;
const root = @This();

const allocator = std.heap.page_allocator;

/// The max number of consecutive masking characers.
const MAX_NUMBER_OF_STARS = 15;

/// Iterates a slice ignoring the next line characters.
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


/// Masks specific words in the input string with the asterisks.
pub fn mask(args: struct { input: py.PyBytes(root), words: py.PyTuple(root), limit: u64 = MAX_NUMBER_OF_STARS }) !py.PyBytes(root) {
    const max_number_of_stars = args.limit;
    const input_slice = try args.input.asSlice();
    var input_it = NoNewLineIterator.create(input_slice);

    var buf = try allocator.allocSentinel(u8, input_slice.len, 0);
    defer allocator.free(buf);
    @memcpy(buf, input_slice);

    for (0..args.words.length()) |pos| {
        const item = try args.words.getItem(py.PyBytes(root), pos);
        var item_it = NoNewLineIterator.create(try item.asSlice());

        var item_i, var item_char = item_it.next() orelse continue;
        const item_start = item_i;
        const item_first_char = item_char;

        var match_start: usize = 0;
        var next_match: usize = 0;
        while (input_it.next()) |r| {
            const i, const char = r;
            if (char == item_char) {
                if (item_i == item_start) {
                    match_start = i;
                } else if (next_match == 0 and char == item_first_char) {
                    next_match = i;
                }
                if (item_it.next()) |p| {
                    item_i, item_char = p;
                } else {
                    for (buf[match_start..i + 1]) |*b| {
                        if (b.* != '\n') b.* = '*';
                    }
                    item_it.reset();
                    item_i, item_char = item_it.next().?; // It cannot be empty at this point.
                    next_match = 0;
                }
            } else if (item_i > item_start) {
                item_it.reset();
                item_i, item_char = item_it.next().?; // It cannot be empty at this point.
                if (next_match == 0) {
                    input_it.index -= 1;
                } else {
                    input_it.index = next_match;
                    next_match = 0;
                }
            }
        }
        input_it.reset();
    }
    // Limit the number of consecutive masking characters.
    var i: usize = 0;
    var num_stars: usize = 0;
    for (buf) |*ptr| {
        buf[i] = ptr.*;
        i += 1;
        if (ptr.* == '*') {
            num_stars += 1;
            if (num_stars > max_number_of_stars) {
                i -= 1;
            }
        } else {
            num_stars = 0;
        }
    }
    buf[i] = 0;
    const res = py.PyBytes(root).create(buf[0..i]);
    return res;
}

comptime {
    py.rootmodule(root);
}
