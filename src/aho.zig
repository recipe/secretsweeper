const std = @import("std");
const testing = std.testing;

const MAX_INT = std.math.maxInt(usize);

/// A mid-size edge container: an unsorted array scanned linearly.
const Few = struct {
    keys: [16]u8,
    ids: [16]u32,
    count: u8,
};

/// Adaptive edge container, sized by the number of children (ART-style).
/// Trie nodes are overwhelmingly chains (~96% have exactly one child), so the
/// 0/1-child cases are stored inline with no heap allocation; the rare branchy
/// nodes upgrade to a linear array and then to a dense direct-indexed table.
const Edges = union(enum) {
    none: void,
    one: struct { key: u8, id: u32 },
    few: *Few,
    dense: *[256]u32,
};

const Node = struct {
    /// Outgoing edges, adaptively sized.
    edges: Edges = .none,
    /// The identifier of the trie node that acts as the fail move.
    fail: u32 = 0,
    /// Pattern length.
    len: u32 = 0,
    /// A search pattern identifier.
    id: u32 = 0,
    /// The trie depth of this node: the length of the pattern prefix it represents.
    depth: u32 = 0,

    /// Returns the child node identifier for byte `c`, or null when there is no edge.
    fn child(self: *const Node, c: u8) ?usize {
        switch (self.edges) {
            .none => return null,
            .one => |edge| return if (edge.key == c) edge.id else null,
            .few => |few| {
                // Branchless membership test: one 16-byte vector compare.
                const keys: @Vector(16, u8) = few.keys;
                const matches: u16 = @bitCast(keys == @as(@Vector(16, u8), @splat(c)));
                const valid = matches & @as(u16, @truncate((@as(u32, 1) << @as(u5, @intCast(few.count))) - 1));
                if (valid == 0) {
                    return null;
                }
                return few.ids[@ctz(valid)];
            },
            .dense => |dense| {
                const id = dense[c];
                // The root is never a child, so 0 marks a missing edge.
                return if (id != 0) id else null;
            },
        }
    }

    /// Adds an edge for byte `c` leading to the node `child_id`,
    /// upgrading the container when it outgrows its size class.
    fn addChild(self: *Node, allocator: std.mem.Allocator, c: u8, child_id: u32) !void {
        switch (self.edges) {
            .none => self.edges = .{ .one = .{ .key = c, .id = child_id } },
            .one => |edge| {
                const few = try allocator.create(Few);
                few.keys = @splat(0); // the vector compare reads all 16 keys
                few.count = 2;
                few.keys[0] = edge.key;
                few.ids[0] = edge.id;
                few.keys[1] = c;
                few.ids[1] = child_id;
                self.edges = .{ .few = few };
            },
            .few => |few| {
                if (few.count < few.keys.len) {
                    few.keys[few.count] = c;
                    few.ids[few.count] = child_id;
                    few.count += 1;
                    return;
                }
                const dense = try allocator.create([256]u32);
                @memset(dense, 0);
                for (few.keys, few.ids) |key, id| {
                    dense[key] = id;
                }
                dense[c] = child_id;
                allocator.destroy(few);
                self.edges = .{ .dense = dense };
            },
            .dense => |dense| dense[c] = child_id,
        }
    }

    fn deinitEdges(self: *Node, allocator: std.mem.Allocator) void {
        switch (self.edges) {
            .few => |few| allocator.destroy(few),
            .dense => |dense| allocator.destroy(dense),
            else => {},
        }
    }
};

/// Aho-Corasick automaton class.
pub const Aho = struct {
    allocator: std.mem.Allocator,

    // Automaton related variables:

    /// A list of all existing nodes.
    nodes: std.ArrayList(Node),
    /// A dense transition table for the root node, filled by `build`. Most of the
    /// input walks through the root, so this keeps the hot path to a single load
    /// while inner nodes stay sparse.
    root_moves: [256]u32 = [_]u32{0} ** 256,
    /// Total number of patterns.
    pidx: usize,
    /// The total number of nodes.
    total: usize,

    // Sweeper related variables:

    /// The last found pattern is used to detect overlapping patterns.
    /// It is a position of the last character of the pattern in the input string.
    /// As this automaton always detects the leftmost-longest pattern first we don't need
    /// to take into consideration all possible overlap cases.
    last_occur: struct {
        /// The position of the last character of the pattern in the input.
        /// It can be negative for the position in the previous line of the streaming mode.
        /// A value of -1 means that no occurrences of any pattern have been found yet.
        pos: isize = -1,
        /// The pattern length.
        len: usize = 0,
        /// Cumulative size.
        /// If there are two or more overlapping patterns it stands for the total length.
        cum_len: usize = 0,

        /// Returns the number of characters outside the overlap boundary
        /// if the given pattern occurrence overlaps, or MAX_INT otherwise.
        /// This is the difference between the last character positions of the two patterns.
        fn overlapReminder(
            self_: *@This(),
            /// The position of the last character of the given pattern.
            pos: usize,
            /// The length of the given pattern.
            len: usize
        ) usize {
            if (@as(isize, @intCast(pos)) - @as(isize, @intCast(len)) < self_.pos) {
                return @intCast(@as(isize, @intCast(pos)) - self_.pos);
            }
            return MAX_INT;
        }
    },
    /// In the streaming mode it may hold a reminder of the previous line that should be taken into consideration
    /// in the consecutive call.
    reminder: ?[]u8 = null,
    /// Current state in the trie.
    state: usize = 0,

    pub fn init(allocator: std.mem.Allocator) !Aho {
        var nodes= try std.ArrayList(Node).initCapacity(allocator, 0);
        // Root node
        try nodes.append(allocator, Node{});
        return Aho{
            .allocator = allocator,
            .nodes = nodes,
            .pidx = 0,
            .total = 0,
            .last_occur = .{},
        };
    }

    pub fn reset_reminder(self: *Aho) void {
        if (self.reminder) |reminder| {
            self.allocator.free(reminder);
            self.reminder = null;
        }
    }

    pub fn deinit(self: *Aho) void {
        self.reset_reminder();
        for (self.nodes.items) |*node| {
            node.deinitEdges(self.allocator);
        }
        self.nodes.deinit(self.allocator);
    }

    /// Returns the next state for byte `c`, following fail links while the state
    /// has no edge for it. Fail-link walks amortize to O(1) per input byte.
    fn goTo(self: *const Aho, state: usize, c: u8) usize {
        var s = state;
        while (s != 0) {
            if (self.nodes.items[s].child(c)) |next| {
                return next;
            }
            s = self.nodes.items[s].fail;
        }
        return self.root_moves[c];
    }

    /// Inserts a new pattern and returns its unique identifier.
    /// Empty pattern is ignored. In this case function returns null.
    pub fn insert(self: *Aho, pattern: []const u8) !?usize {
        if (pattern.len == 0) {
            // Ignore empty patterns.
            return null;
        }
        var u: usize = 0;
        for (pattern) |c| {
            if (self.nodes.items[u].child(c)) |v| {
                // Transition to an existing node.
                u = v;
                continue;
            }
            // Insert a new node to a trie.
            self.total += 1;
            if (self.total > std.math.maxInt(u32)) {
                return error.TooManyNodes;
            }
            const child_depth = self.nodes.items[u].depth + 1;
            try self.nodes.append(self.allocator, Node{ .depth = child_depth });
            try self.nodes.items[u].addChild(self.allocator, c, @intCast(self.total));
            u = self.total;
        }
        if (self.nodes.items[u].id == 0) {
            self.pidx += 1;
            // Both fit in u32: nodes are counted per pattern byte, and `insert`
            // fails with TooManyNodes before the node count can exceed it.
            self.nodes.items[u].id = @intCast(self.pidx);
            self.nodes.items[u].len = @intCast(pattern.len);
        }
        return self.nodes.items[u].id;
    }

    /// Build fail links in breadth-first order.
    pub fn build(self: *Aho) !void {
        var queue = try std.ArrayList(usize).initCapacity(self.allocator, 0);
        defer queue.deinit(self.allocator);

        for (0..256) |i| {
            self.root_moves[i] = @intCast(self.nodes.items[0].child(@intCast(i)) orelse 0);
        }

        try queue.append(self.allocator, 0);
        var head: usize = 0;
        while (head < queue.items.len) {
            const u = queue.items[head];
            head += 1;
            for (0..256) |i| {
                const c: u8 = @intCast(i);
                if (self.nodes.items[u].child(c)) |v| {
                    if (u != 0) {
                        // The fail link of a deeper node continues from its parent's
                        // fail link; children of the root keep the root as the fail.
                        self.nodes.items[v].fail = @intCast(self.goTo(self.nodes.items[u].fail, c));
                    }
                    try queue.append(self.allocator, v);
                }
            }
        }
    }

    /// Mask all patterns in the text string with the star character.
    pub fn mask(self: *Aho, args: struct {
        /// An input string.
        text: []const u8,
        /// The max number of stars to mask patterns in the result.
        max_stars: u64 = 15,
        /// In streaming mode, incomplete patterns at the end of the input are buffered and processed on the next call.
        /// The function does not process the entire text at once if an incomplete pattern is found at the end
        /// of the input. Instead, it saves the remainder in its internal state and uses it in the next call,
        /// treating the input as a continuation of the previous one.
        is_streaming: bool = false,
    }) ![]u8 {
        if (!args.is_streaming) {
            self.reset_reminder();
            self.state = 0;
            self.last_occur = .{};
        }
        const reminder_len = if (self.reminder) |reminder| reminder.len else 0;
        const input_len = reminder_len + args.text.len;
        // Result buffer.
        var buf = try self.allocator.alloc(u8, input_len);
        // The actual buffer length.
        var buf_len: usize = 0;
        if (reminder_len > 0) {
            // Copy reminder to the buffer to restore the state and continue.
            @memcpy(buf[0..reminder_len], self.reminder.?[0..reminder_len]);
            buf_len = reminder_len;
        }
        for (args.text, 0..) |c, pos| {
            // Walk the automaton.
            self.state = self.goTo(self.state, c);
            // Copy from input character by character.
            buf[buf_len] = c;
            buf_len += 1;
            // Pattern found and should be masked.
            if (self.nodes.items[self.state].id > 0) {
                // This is the difference between the last character positions of the two patterns.
                const num = self.last_occur.overlapReminder(pos, self.nodes.items[self.state].len);
                self.last_occur.cum_len = if (num == MAX_INT) self.nodes.items[self.state].len else self.last_occur.cum_len + num;
                // Replace the last found pattern position and length.
                // Defer is used because under some conditions the block may exit with the continue below.
                defer {
                    self.last_occur.pos = @intCast(pos);
                    self.last_occur.len = self.nodes.items[self.state].len;
                }
                // Difference between the pattern length and max number of stars.
                // If this difference is greater than 0 we need to limit the mask.
                // For overlapping patterns, we must account for the stars already printed by the previous pattern.
                var diff: usize = 0;
                if (self.last_occur.cum_len > args.max_stars) {
                    diff = self.last_occur.cum_len - args.max_stars;
                    diff = @min(num, diff);
                }
                buf_len -= diff;
                var size = self.nodes.items[self.state].len - diff;
                if (num < MAX_INT) {
                    if (self.last_occur.len >= args.max_stars) {
                        continue;
                    }
                    size = @min(num, size);
                }
                // Mask the pattern in the buffer.
                @memset(buf[buf_len - size..buf_len], '*');
            }
        }
        var new_reminder_len: usize = 0;
        if (args.is_streaming) {
            self.reset_reminder();
            // Only the current state's trie depth of trailing bytes can still belong to
            // a future match, so retaining more would grow the reminder without bound
            // on inputs that keep the automaton away from the starting state.
            // Masking may have shrunk the buffer below that depth; retain what exists.
            new_reminder_len = @min(self.nodes.items[self.state].depth, buf_len);
            if (new_reminder_len > 0) {
                self.reminder = try self.allocator.alloc(u8, new_reminder_len);
                @memcpy(self.reminder.?, buf[buf_len - new_reminder_len..buf_len]);
            }
            self.last_occur.pos = self.last_occur.pos - @as(isize, @intCast(args.text.len));
        }
        if (buf_len < input_len or new_reminder_len > 0) {
            buf = try self.allocator.realloc(buf, buf_len - new_reminder_len);
        }
        return buf;
    }
};

test "Aho" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ac = try Aho.init(allocator);

    const patterns1 = [_][]const u8{"her", "hers", "ash"};
    for (0..patterns1.len) |i| {
        _ = try ac.insert(patterns1[i]);
    }

    try testing.expectEqual(7, ac.total);

    try ac.build();

    const masked = try ac.mask(.{ .text= "asher" });
    defer allocator.free(masked);
    try testing.expectEqualStrings("*****", masked);

    const masked_limit = try ac.mask(.{ .text= "her asher", .max_stars = 1 });
    defer allocator.free(masked_limit);
    try testing.expectEqualStrings("* *", masked_limit);

    const sanitized = try ac.mask(.{ .text= "her asher", .max_stars = 0 });
    defer allocator.free(sanitized);
    try testing.expectEqualStrings(" ", sanitized);

    ac.deinit();

    ac = try Aho.init(allocator);
    const patterns2 = [_][]const u8{"ne\nse", "second"};
    for (0..patterns2.len) |i| {
        _ = try ac.insert(patterns2[i]);
    }
    try ac.build();

    const masked_overlapped = try ac.mask(.{ .text= "line\nsecond line\n", .max_stars= 6 });
    defer allocator.free(masked_overlapped);
    try testing.expectEqualStrings("li****** line\n", masked_overlapped);

    ac.deinit();

    ac = try Aho.init(allocator);
    _ = try ac.insert("line");
    try ac.build();
    var file_content = [_][]const u8{"first line\n", "second line\n", "third line\n"};
    var expected = [_][]const u8{"first ****\n", "second ****\n", "third ****\n"};
    for (0..file_content.len) |i| {
        const buffer = try ac.mask(.{ .text= file_content[i], .is_streaming = true });
        defer allocator.free(buffer);
        try testing.expectEqualStrings(expected[i], buffer);
        try testing.expectEqualStrings("", ac.reminder orelse "");
    }

    ac.deinit();

    ac = try Aho.init(allocator);
    _ = try ac.insert("st line\nsecond line\nthird ");
    try ac.build();
    file_content = [_][]const u8{"first line\n", "second line\n", "third line\n"};
    expected = [_][]const u8{"fir", "", "*line\n"};
    var expected_reminder = [_][]const u8{"st line\n", "st line\nsecond line\n", ""};
    for (0..file_content.len) |i| {
        const buffer = try ac.mask(.{ .text= file_content[i], .is_streaming = true, .max_stars = 1 });
        defer allocator.free(buffer);
        try testing.expectEqualStrings(expected[i], buffer);
        try testing.expectEqualStrings(expected_reminder[i], ac.reminder orelse "");
    }

    ac.deinit();

    ac = try Aho.init(allocator);
    defer ac.deinit();
    _ = try ac.insert("st line\nsecond line\nthird line\n");
    try ac.build();
    file_content = [_][]const u8{"first line\n", "second line\n", "third line\n"};
    expected = [_][]const u8{"fir", "", ""};
    expected_reminder = [_][]const u8{"st line\n", "st line\nsecond line\n", "*"};
    for (0..file_content.len) |i| {
        const buffer = try ac.mask(.{ .text= file_content[i], .is_streaming = true, .max_stars = 1 });
        defer allocator.free(buffer);
        try testing.expectEqualStrings(expected[i], buffer);
        try testing.expectEqualStrings(expected_reminder[i], ac.reminder orelse "");
    }
    try testing.expectEqualStrings("*", ac.reminder orelse "");
}

test "Aho reminder is bounded by the longest pattern prefix" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ac = try Aho.init(allocator);
    defer ac.deinit();
    _ = try ac.insert("ab");
    try ac.build();

    // The automaton never returns to the starting state on this input, but only
    // the trailing "a" can still be part of a match: everything else is emitted.
    var expected: []const u8 = "aaa";
    for (0..3) |i| {
        const buffer = try ac.mask(.{ .text = "aaaa", .is_streaming = true });
        defer allocator.free(buffer);
        if (i > 0) {
            // The retained "a" is prepended, so full chunks are emitted from now on.
            expected = "aaaa";
        }
        try testing.expectEqualStrings(expected, buffer);
        try testing.expectEqualStrings("a", ac.reminder orelse "");
    }

    // The retained "a" combines with a "b" in the next chunk into a match.
    // The stars are withheld while a following pattern could still overlap them.
    const masked = try ac.mask(.{ .text = "b", .is_streaming = true });
    defer allocator.free(masked);
    try testing.expectEqualStrings("", masked);
    try testing.expectEqualStrings("**", ac.reminder orelse "");

    const rest = try ac.mask(.{ .text = "c", .is_streaming = true });
    defer allocator.free(rest);
    try testing.expectEqualStrings("**c", rest);
    try testing.expectEqualStrings("", ac.reminder orelse "");
}
