//! C ABI exports over the Aho-Corasick automaton, consumed by the Python
//! `secretsweeper._core` module through ctypes.
//!
//! Every function returning `i32` uses 0 for success and -1 for an allocation
//! failure. Buffers returned via `ss_mask` are owned by the caller and must be
//! released with `ss_free`.
const std = @import("std");
const Aho = @import("aho.zig").Aho;

const allocator = std.heap.c_allocator;

/// Create a new automaton. Returns null on allocation failure.
export fn ss_new() ?*Aho {
    const ac = allocator.create(Aho) catch return null;
    ac.* = Aho.init(allocator) catch {
        allocator.destroy(ac);
        return null;
    };
    return ac;
}

/// Destroy an automaton created with `ss_new`.
export fn ss_destroy(ac: *Aho) void {
    ac.deinit();
    allocator.destroy(ac);
}

/// Insert a search pattern. Must be called before `ss_build`.
export fn ss_insert(ac: *Aho, pattern: [*]const u8, len: usize) i32 {
    _ = ac.insert(pattern[0..len]) catch return -1;
    return 0;
}

/// Build goto and fail functions. Call once, after all patterns are inserted.
export fn ss_build(ac: *Aho) i32 {
    ac.build() catch return -1;
    return 0;
}

/// Mask all patterns in the text with the star character.
///
/// On success writes the result buffer to `out_ptr`/`out_len` and returns 0.
/// An empty result is reported as a null `out_ptr` with `out_len` 0 and needs
/// no `ss_free` call.
export fn ss_mask(
    ac: *Aho,
    text: [*]const u8,
    len: usize,
    max_stars: u64,
    is_streaming: bool,
    out_ptr: *?[*]u8,
    out_len: *usize,
) i32 {
    const masked = ac.mask(.{
        .text = text[0..len],
        .max_stars = max_stars,
        .is_streaming = is_streaming,
    }) catch return -1;
    if (masked.len == 0) {
        allocator.free(masked);
        out_ptr.* = null;
        out_len.* = 0;
        return 0;
    }
    out_ptr.* = masked.ptr;
    out_len.* = masked.len;
    return 0;
}

/// Release a buffer returned by `ss_mask`.
export fn ss_free(ptr: ?[*]u8, len: usize) void {
    if (ptr) |p| {
        if (len > 0) {
            allocator.free(p[0..len]);
        }
    }
}

/// Get the streaming-mode reminder. Returns a pointer into the automaton's
/// internal state that stays valid until the next `ss_mask`/`ss_reset_reminder`
/// call; the caller must copy it and must not free it.
export fn ss_get_reminder(ac: *Aho, out_len: *usize) ?[*]const u8 {
    const reminder = ac.reminder orelse {
        out_len.* = 0;
        return null;
    };
    out_len.* = reminder.len;
    return reminder.ptr;
}

/// Reset the streaming-mode reminder.
export fn ss_reset_reminder(ac: *Aho) void {
    ac.reset_reminder();
}

test {
    _ = @import("aho.zig");
}

test "C ABI roundtrip" {
    const ac = ss_new().?;
    defer ss_destroy(ac);

    try std.testing.expectEqual(0, ss_insert(ac, "her", 3));
    try std.testing.expectEqual(0, ss_build(ac));

    var out_ptr: ?[*]u8 = null;
    var out_len: usize = 0;
    try std.testing.expectEqual(0, ss_mask(ac, "asher", 5, 15, false, &out_ptr, &out_len));
    defer ss_free(out_ptr, out_len);
    try std.testing.expectEqualStrings("as***", out_ptr.?[0..out_len]);
}

test "C ABI streaming roundtrip" {
    const ac = ss_new().?;
    defer ss_destroy(ac);

    try std.testing.expectEqual(0, ss_insert(ac, "her", 3));
    try std.testing.expectEqual(0, ss_build(ac));

    var out_ptr: ?[*]u8 = null;
    var out_len: usize = 0;
    // "ashe" ends with a partial match: "he" is held back as the reminder.
    try std.testing.expectEqual(0, ss_mask(ac, "ashe", 4, 15, true, &out_ptr, &out_len));
    try std.testing.expectEqualStrings("as", out_ptr.?[0..out_len]);
    ss_free(out_ptr, out_len);
    // "rs" completes "her": the reminder is flushed, output longer than input.
    try std.testing.expectEqual(0, ss_mask(ac, "rs", 2, 15, true, &out_ptr, &out_len));
    try std.testing.expectEqualStrings("***s", out_ptr.?[0..out_len]);
    ss_free(out_ptr, out_len);
}
