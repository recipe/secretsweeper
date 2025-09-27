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

    pub fn init(allocator: std.mem.Allocator) !Aho {
        var nodes= std.ArrayList(Node).init(allocator);
        // Root node
        try nodes.append(Node{});
        return Aho{
            .allocator = allocator,
            .nodes = nodes,
            .pidx = 0,
            .total = 0,
        };
    }

    pub fn deinit(self: *Aho) void {
        self.nodes.deinit();
    }

    /// Inserts a new pattern and returns its unique identifier.
    pub fn insert(self: *Aho, pattern: []const u8) !usize {
        var u: usize = 0;
        for (pattern) |c| {
            if (self.nodes.items[u].move[c] == 0) {
                // Insert a new node to a trie.
                self.total += 1;
                try self.nodes.append(Node{});
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

    /// Build the goto and fail functions.
    pub fn build(self: *Aho) !void {
        var queue = std.fifo.LinearFifo(usize, .Dynamic).init(self.allocator);
        defer queue.deinit();

        for (0..256) |i| {
            if (self.nodes.items[0].move[i] != 0) {
                try queue.writeItem(self.nodes.items[0].move[i]);
            }
        }

        while (queue.readItem()) |u| {
            for (0..256) |i| {
                const transition_node_id = self.nodes.items[u].move[i];
                const fail_node_id = self.nodes.items[u].fail;
                if (transition_node_id != 0) {
                    self.nodes.items[transition_node_id].fail = self.nodes.items[fail_node_id].move[i];
                    try queue.writeItem(transition_node_id);
                } else {
                    self.nodes.items[u].move[i] = self.nodes.items[fail_node_id].move[i];
                }
            }
        }
    }



    /// Mask all patterns in the text string with the star character.
    pub fn mask(self: *Aho, args: struct {
        /// An input string
        text: []const u8,
        /// The max number of stars to mask patterns in the result.
        max_stars: u64 = 15,
    }) ![]u8 {
        // Result buffer.
        var buf = try self.allocator.alloc(u8, args.text.len);
        // The actual buffer length.
        var buf_len: usize = 0;
        // A state in the trie.
        var u: usize = 0;

        // The last found pattern is used to detect overlapping patterns.
        // It is a position of the last character of the pattern in the input string.
        // As this automaton always detects the leftmost-lognest pattern first we don't need
        // to take into consideration all possible overlap casess.
        var last_occur = struct {
            /// A position of the last character of the pattern in the input.
            /// -1 value means that there has not been occurrences of any patterns yet.
            pos: isize = -1,
            /// The pattern length.
            len: usize = 0,

            /// Return the number of characters that are out of the overlap boundary
            /// if the given pattern occurrence is overlapping, or MAX_INT otherwise.
            fn overlapReminder(self_: *@This(), pos: usize, len: usize) usize {
                if (@as(isize, @intCast(pos)) - @as(isize, @intCast(len)) < self_.pos) {
                    return pos - @as(usize, @intCast(self_.pos));
                }
                return std.math.maxInt(usize);
            }
        }{};

        for (args.text, 0..) |c, pos| {
            // Walk the automaton.
            u = self.nodes.items[u].move[c];
            // Copy from input character by character.
            buf[buf_len] = c;
            buf_len += 1;
            // Pattern found and should be masked.
            if (self.nodes.items[u].id > 0) {
                // Replace the last found pattern eventually.
                defer {
                    last_occur.pos = @as(isize, @intCast(pos));
                    last_occur.len = self.nodes.items[u].len;
                }
                // A number of characters that are out of the overlap boundary.
                const num = last_occur.overlapReminder(pos, self.nodes.items[u].len);
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
                    if (last_occur.len >= args.max_stars) {
                        continue;
                    }
                    size = @min(num, size);
                }
                // Mask the pattern in the buffer.
                @memset(buf[buf_len - size..buf_len], '*');
            }
        }
        if (buf_len < args.text.len) {
            buf = try self.allocator.realloc(buf, buf_len);
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
