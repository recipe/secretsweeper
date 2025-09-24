const py = @import("pydust");
const std = @import("std");
const ffi = py.ffi;
const root = @This();
const py_allocator = py.allocator;
const Aho = @import("aho.zig").Aho;

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
    _ = max_number_of_stars; // TODO Should be added soon
    const input_slice = try args.input.asSlice();

    var ac = try Aho.init(py_allocator);
    defer ac.deinit();

    for (0..args.words.length()) |pos| {
        const item = try args.words.getItem(py.PyBytes(root), pos);
        _ = try ac.insert(try item.asSlice());
    }
    try ac.build();
    const masked = try ac.mask(input_slice);
    defer py_allocator.free(masked);

    const res = py.PyBytes(root).create(masked);
    return res;
}

comptime {
    py.rootmodule(root);
}
