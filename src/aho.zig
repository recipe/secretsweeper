const std = @import("std");
const testing = std.testing;

const Node = struct {
    /// Links to child trie nodes.
    move: [256]usize = [_]usize{0} ** 256,
    /// The identifier of the trie node that acts as the fail move.
    fail: usize = 0,
    /// Pattern length.
    len: usize = 0,
    /// Degree for topological sort.
    du: usize  = 0,
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
                    const target_fail_node_id = self.nodes.items[transition_node_id].fail;
                    self.nodes.items[target_fail_node_id].du += 1;

                    try queue.writeItem(transition_node_id);
                } else {
                    self.nodes.items[u].move[i] = self.nodes.items[fail_node_id].move[i];
                }
            }
        }
    }

    /// Mask all patterns in the text string with the star character.
    pub fn mask(self: *Aho, text: []const u8) ![]u8 {
        var buf = try self.allocator.alloc(u8, text.len);
        var u: usize = 0;
        var buf_pos: usize = 0;
        for (text) |c| {
            buf[buf_pos] = c;
            buf_pos += 1;
            u = self.nodes.items[u].move[c];
            if (self.nodes.items[u].id > 0) {
                // Pattern found and should be masked.
                @memset(buf[buf_pos - self.nodes.items[u].len..buf_pos], '*');
            }
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

    const patterns = [_][]const u8{"her", "hers", "asher", "ash"};
    for (0..patterns.len) |i| {
        _ = try ac.insert(patterns[i]);
    }

    try testing.expectEqual(9, ac.total);

    try ac.build();

    const text = "her asher crashed to ash";
    const masked = try ac.mask(text);
    defer allocator.free(masked);

    try testing.expectEqualStrings("*** ***** cr***ed to ***", masked);
}
