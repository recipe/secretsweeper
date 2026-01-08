const std = @import("std");
const testing = std.testing;

const Node = struct {
    /// Links to child trie nodes.
    move: [256]usize = [_]usize{0} ** 256,
    /// The identifier of the trie node that acts as the fail move.
    fail: usize = 0,
    /// Pattern length.
    len: usize = 0,
    /// A search pattern identifier.
    id: usize = 0,
};

pub const Aho = struct {
    allocator: std.mem.Allocator,
    /// A list of all existing nodes.
    nodes: std.ArrayList(Node),
    /// Total number of patterns.
    pidx: usize,
    /// The total number of nodes.
    total: usize,
    /// The last found pattern is used to detect overlapping patterns.
    /// It is a position of the last character of the pattern in the input string.
    /// As this automaton always detects the leftmost-longest pattern first we don't need
    /// to take into consideration all possible overlap cases.
    last_occur: struct {
        /// The position of the last character of the pattern in the input.
        /// A value of -1 means that no occurrences of any pattern have been found yet.
        pos: isize = -1,
        /// The pattern length.
        len: usize = 0,

        /// Returns the number of characters outside the overlap boundary
        /// if the given pattern occurrence overlaps, or MAX_INT otherwise.
        fn overlapReminder(self_: *@This(), pos: usize, len: usize) usize {
            if (@as(isize, @intCast(pos)) - @as(isize, @intCast(len)) < self_.pos) {
                return pos - @as(usize, @intCast(self_.pos));
            }
            return std.math.maxInt(usize);
        }
    },
    /// In the streaming mode it may hold a reminder of the previous line that should be taken into consideration
    /// in the consecutive call.
    reminder: ?[]u8,
    /// The most recent position in the input where the automaton was in the starting state.
    last_starting_state_pos: isize = -1,

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
            .reminder = null,
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
        self.nodes.deinit(self.allocator);
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
            if (self.nodes.items[u].move[c] == 0) {
                // Insert a new node to a trie.
                self.total += 1;
                try self.nodes.append(self.allocator, Node{});
                self.nodes.items[u].move[c] = self.total;
            }
            // Transition to a new node.
            u = self.nodes.items[u].move[c];
        }
        if (self.nodes.items[u].id == 0) {
            self.pidx += 1;
            self.nodes.items[u].id = self.pidx;
            self.nodes.items[u].len = pattern.len;
        }
        return self.nodes.items[u].id;
    }

    /// Build goto and fail functions.
    pub fn build(self: *Aho) !void {
        var queue = try std.ArrayList(usize).initCapacity(self.allocator, 0);
        defer queue.deinit(self.allocator);

        for (0..256) |i| {
            if (self.nodes.items[0].move[i] != 0) {
                try queue.append(self.allocator, self.nodes.items[0].move[i]);
            }
        }

        var head: usize = 0;
        while (head < queue.items.len) {
            const u = queue.items[head];
            head += 1;
            for (0..256) |i| {
                const transition_node_id = self.nodes.items[u].move[i];
                const fail_node_id = self.nodes.items[u].fail;
                if (transition_node_id != 0) {
                    self.nodes.items[transition_node_id].fail = self.nodes.items[fail_node_id].move[i];
                    try queue.append(self.allocator, transition_node_id);
                } else {
                    self.nodes.items[u].move[i] = self.nodes.items[fail_node_id].move[i];
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
        self.last_starting_state_pos = 0;
        // Resetting the last occurrence of the found pattern.
        self.last_occur = .{};
        if (!args.is_streaming) {
            self.reset_reminder();
        }
        const reminder_len = (self.reminder orelse "").len;
        const input_len = reminder_len + args.text.len;
        // Result buffer.
        var buf = try self.allocator.alloc(u8, reminder_len + args.text.len);
        // The actual buffer length.
        var buf_len: usize = 0;
        // A state in the trie.
        var u: usize = 0;
        // Position in the input, taking into account the remainder.
        var pos: usize = 0;
        while (pos < input_len): (pos += 1) {
            const c = if (pos < reminder_len) self.reminder.?[pos] else args.text[pos - reminder_len];
            // Walk the automaton.
            u = self.nodes.items[u].move[c];
            if (u == 0) {
                self.last_starting_state_pos = @intCast(pos);
            }
            // Copy from input character by character.
            buf[buf_len] = c;
            buf_len += 1;
            // Pattern found and should be masked.
            if (self.nodes.items[u].id > 0) {
                // Replace the last found pattern eventually.
                defer {
                    self.last_occur.pos = @intCast(pos);
                    self.last_occur.len = self.nodes.items[u].len;
                }
                // A number of characters that are out of the overlap boundary.
                const num = self.last_occur.overlapReminder(pos, self.nodes.items[u].len);
                // Difference between the pattern length and max number of stars.
                // If this difference is greater than 0 we need to limit the mask.
                var diff: usize = 0;
                if (self.nodes.items[u].len > args.max_stars) {
                    diff = self.nodes.items[u].len - args.max_stars;
                    diff = @min(num, diff);
                }
                buf_len -= diff;
                var size = self.nodes.items[u].len - diff;
                if (num < std.math.maxInt(usize)) {
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
        if (args.is_streaming and self.last_starting_state_pos < input_len) {
            new_reminder_len = @intCast(@as(isize, @intCast(input_len)) - self.last_starting_state_pos - 1);
            self.reminder = try self.allocator.alloc(u8, new_reminder_len);
            @memcpy(self.reminder.?, buf[buf_len - new_reminder_len..buf_len]);
        }
        if (buf_len < input_len or new_reminder_len > 0) {
            buf = try self.allocator.realloc(buf, buf_len - new_reminder_len);
        }
        return buf;
    }
};

test "Aho" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ac = try Aho.init(allocator);
    defer ac.deinit();

    const patterns = [_][]const u8{"her", "hers", "ash"};
    for (0..patterns.len) |i| {
        _ = try ac.insert(patterns[i]);
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
}
