const py = @import("pydust");
const std = @import("std");
const ffi = py.ffi;
const root = @This();
const py_allocator = py.allocator;
const Aho = @import("aho.zig").Aho;

/// The max number of consecutive masking characers.
const MAX_NUMBER_OF_STARS = 15;

/// Masks specific patterns in the input string with the asterisks.
pub fn mask(args: struct { input: py.PyBytes(root), patterns: py.PyTuple(root), limit: u64 = MAX_NUMBER_OF_STARS }) !py.PyBytes(root) {
    const max_number_of_stars = args.limit;

    var ac = try Aho.init(py_allocator);
    defer ac.deinit();

    for (0..args.patterns.length()) |pos| {
        const item = try args.patterns.getItem(py.PyBytes(root), pos);
        _ = try ac.insert(try item.asSlice());
    }
    try ac.build();
    const masked = try ac.mask(.{ .text = try args.input.asSlice(), .max_stars = max_number_of_stars });
    defer py_allocator.free(masked);

    const res = py.PyBytes(root).create(masked);
    return res;
}

comptime {
    py.rootmodule(root);
}
