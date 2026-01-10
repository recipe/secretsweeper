const py = @import("pydust");
const std = @import("std");
const ffi = py.ffi;
const root = @This();
const py_allocator = py.allocator;
const Aho = @import("aho.zig").Aho;

/// The default value of the max number of consecutive masking characters.
pub const MAX_NUMBER_OF_STARS = 15;

/// Aho-Corasick automaton container.
var aho_map: std.AutoHashMap(usize, *Aho) = .init(py_allocator);

pub const _StreamWrapper = py.class(struct {
    pub const __doc__ =
        \\The StreamWrapper wraps an io.BytesIO stream to mask or remove secrets while reading from it.
    ;
    const Self = @This();
    limit: u64,

    /// Initialize the StreamWrapper instance.
    ///
    /// Args:
    ///     stream (typing.IO[bytes]): A file-like object or I/O stream that handles binary data.
    ///     patterns (typing.Iterable[bytes]): Any iterable of patterns that have to be masked with the `*` asterisk character.
    ///     limit (int): The max number of consecutive stars.
    pub fn __init__(self: *Self, args: struct { patterns: py.PyObject, limit: u64 = MAX_NUMBER_OF_STARS }) !void {
        self.* = .{ .limit = args.limit};
        // Initialize the automaton only once.
        const ac = try py_allocator.create(Aho);
        ac.* = try Aho.init(py_allocator);
        try aho_map.put(self._id(), ac);
        // Apply patterns and build the automaton.
        const iterator = try py.iter(root, args.patterns);
        while (try iterator.next(py.PyBytes)) |item| {
            _ = try ac.*.insert(try item.asSlice());
        }
        try ac.*.build();
    }

    /// Return the identity of this object.
    pub fn _id(self: *Self) usize {
        return @intFromPtr(py.object(root, self).py);
    }

    /// Class destructor.
    pub fn __del__(self: *Self) void {
        if (aho_map.fetchRemove(self._id())) |entry| {
            entry.value.*.deinit();
            py_allocator.destroy(entry.value);
        }
    }

    /// Read data from the carry buffer and apply pattern masking.
    pub fn masking_read(self: *Self, args: struct { carry: py.PyBytes }) !py.PyBytes {
        const ac = aho_map.get(self._id()).?;
        const masked = try ac.*.mask(.{
            .text = try args.carry.asSlice(),
            .max_stars = self.limit,
            .is_streaming = true,
        });
        defer py_allocator.free(masked);
        const res = try py.PyBytes.create(masked);
        return res;
    }

    /// Return the reminder value and reset it.
    pub fn consume_reminder(self: *Self) !py.PyBytes {
        const ac = aho_map.get(self._id()).?;
        defer ac.*.reset_reminder();
        return self.get_reminder();
    }

    /// Get the value of the reminder.
    pub fn get_reminder(self: *Self) !py.PyBytes {
        const ac = aho_map.get(self._id()).?;
        const reminder = ac.*.reminder orelse "";
        return try py.PyBytes.create(reminder);
    }
});

/// Validate that the input object is a bytes-like object.
fn validate_buffer(obj: py.PyObject) !void {
    const input_type = try obj.getTypeName();

    const typeName = try py.str(root, py.type_(root, obj));
    defer typeName.obj.decref();

    if (!std.mem.eql(u8, "bytes", input_type)
        and !std.mem.eql(u8, "memoryview", input_type)
        and !std.mem.eql(u8, "bytearray", input_type)
    ) {
        const help_note = if (std.mem.eql(u8, "BytesIO", input_type)) ". You can use the StreamWrapper class for such purposes." else "";
        return py.TypeError(root).raiseFmt(
            "expected {s}, found {s}{s}",
            .{
                "bytes, memoryview or bytearray",
                try typeName.asSlice(),
                help_note
            }
        );
    }
}

/// Masks specific patterns in the input string with the asterisks.
pub fn mask(args: struct { input: py.PyObject, patterns: py.PyObject, limit: u64 = MAX_NUMBER_OF_STARS }) !py.PyBytes {
    const max_number_of_stars = args.limit;

    validate_buffer(args.input) catch |err| return err;

    const view = try args.input.getBuffer(root, py.PyBuffer.Flags.ND);
    defer view.release();

    var ac = try Aho.init(py_allocator);
    defer ac.deinit();

    const iterator = try py.iter(root, args.patterns);
    while (try iterator.next(py.PyBytes)) |item| {
        _ = try ac.insert(try item.asSlice());
    }

    try ac.build();
    const masked = try ac.mask(.{ .text = view.asSlice(u8), .max_stars = max_number_of_stars });
    defer py_allocator.free(masked);

    const res = try py.PyBytes.create(masked);
    return res;
}

comptime {
    py.rootmodule(root);
}
