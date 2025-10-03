const py = @import("pydust");
const std = @import("std");
const ffi = py.ffi;
const root = @This();
const py_allocator = py.allocator;
const Aho = @import("aho.zig").Aho;

/// The default value of the max number of consecutive masking characers.
const MAX_NUMBER_OF_STARS = 15;

pub const StreamWrapper = py.class(struct {
    pub const __doc__ =
        \\The StreamWrapper wraps an io.BytesIO stream to mask or remove secrets while reading from it.
    ;
    const Self = @This();
    pub fn __init__(self: *Self) void {
        self.* = .{};
        // Not Implemented Yet
    }
});

/// Masks specific patterns in the input string with the asterisks.
pub fn mask(args: struct { input: py.PyBytes(root), patterns: py.PyObject(root), limit: u64 = MAX_NUMBER_OF_STARS }) !py.PyBytes(root) {
    const max_number_of_stars = args.limit;

    var ac = try Aho.init(py_allocator);
    defer ac.deinit();

    const iterator = try py.iter(root, args.patterns);
    while (try iterator.next(py.PyBytes(root))) |item| {
        _ = try ac.insert(try item.asSlice());
    }

    try ac.build();
    const masked = try ac.mask(.{ .text = try args.input.asSlice(), .max_stars = max_number_of_stars });
    defer py_allocator.free(masked);

    const res = try py.PyBytes(root).create(masked);
    return res;
}

comptime {
    py.rootmodule(root);
}
