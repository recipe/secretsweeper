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
    /// Memory cap for `dfa_table` + `dfa_match` combined (each entry is 4 bytes, so
    /// this bounds `num_states * num_classes` at 8 bytes/entry). Pattern sets that
    /// would exceed it fall back to `build`/`goTo`, which stays fixed-memory
    /// regardless of pattern size — see memory note `no-unbounded-dfa-memory`.
    pub const DFA_MEMORY_CAP: usize = 20 * 1024 * 1024;

    allocator: std.mem.Allocator,

    // Automaton related variables:

    /// A list of all existing nodes.
    nodes: std.ArrayList(Node),
    /// A dense transition table for the root node, filled by `build`. Most of the
    /// input walks through the root, so this keeps the hot path to a single load
    /// while inner nodes stay sparse.
    root_moves: [256]u32 = [_]u32{0} ** 256,
    /// Byte -> class, computed by `buildDfa`. Bytes with no trie edge anywhere
    /// share one class, since `goTo` treats them all identically.
    byte_class: [256]u8 = [_]u8{0} ** 256,
    num_classes: usize = 0,
    /// Premultiplied: `dfa_table[state * num_classes + byte_class[c]]` is
    /// `next_state * num_classes`, ready to use directly as the next lookup index.
    dfa_table: []u32 = &.{},
    /// Parallel to `dfa_table`: matched pattern length (0 if not a match) at the
    /// same index, so match-checking needs no extra address computation.
    dfa_match: []u32 = &.{},
    /// Set by `insert` for every pattern of length >= 2: `bigram_ok[(first << 8) |
    /// second]` is true if some pattern starts with that exact 2-byte prefix.
    /// Used by `mask`'s DFA dispatch to skip a byte entirely (stay at root, no
    /// array lookup at all) when it provably cannot start a match — see the
    /// gate in `mask` for the correctness argument.
    bigram_ok: [65536]bool = [_]bool{false} ** 65536,
    /// Set by `insert` for every pattern of length exactly 1. The bigram gate
    /// above must never skip a byte that is itself a complete match, since a
    /// 1-byte pattern has no "second byte" to record in `bigram_ok`.
    one_byte_match: [256]bool = [_]bool{false} ** 256,
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
        if (self.dfa_table.len > 0) self.allocator.free(self.dfa_table);
        if (self.dfa_match.len > 0) self.allocator.free(self.dfa_match);
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
        if (pattern.len == 1) {
            self.one_byte_match[pattern[0]] = true;
        } else {
            self.bigram_ok[(@as(usize, pattern[0]) << 8) | pattern[1]] = true;
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

    /// One decided piece of output. `literal` copies `[start, end)` of the
    /// combined (reminder + text) input; `stars` emits a run of `*`. Kept as a
    /// list, not one entry per match, because a later overlapping match's
    /// star-cap can reach back through stars an earlier match already emitted —
    /// `ensureTailStars` treats that as already satisfied instead of duplicating it.
    const Op = union(enum) {
        literal: struct { start: usize, end: usize },
        stars: usize,
    };

    /// Drops the last `n` bytes of decided output from `ops`. Always lands inside
    /// the literal run just pushed for the current match (see `mask`): that run's
    /// length equals `num` exactly, and `diff <= num` always holds.
    fn trimTail(ops: *std.ArrayList(Op), n: usize) void {
        var remaining = n;
        while (remaining > 0) {
            const last_idx = ops.items.len - 1;
            switch (ops.items[last_idx]) {
                .literal => |lit| {
                    const len = lit.end - lit.start;
                    if (len <= remaining) {
                        ops.shrinkRetainingCapacity(last_idx);
                        remaining -= len;
                    } else {
                        ops.items[last_idx] = .{ .literal = .{ .start = lit.start, .end = lit.end - remaining } };
                        remaining = 0;
                    }
                },
                .stars => |count| {
                    if (count <= remaining) {
                        ops.shrinkRetainingCapacity(last_idx);
                        remaining -= count;
                    } else {
                        ops.items[last_idx] = .{ .stars = count - remaining };
                        remaining = 0;
                    }
                },
            }
        }
    }

    /// Ensures the last `size` bytes of decided output are stars, converting or
    /// splitting trailing `literal` runs as needed. Stops as soon as it meets a
    /// `stars` run that already covers the rest of `size` — nothing to convert
    /// there, which is what keeps a chain of overlapping star-caps idempotent.
    fn ensureTailStars(ops: *std.ArrayList(Op), allocator: std.mem.Allocator, size: usize) !void {
        var remaining = size;
        var i = ops.items.len;
        while (remaining > 0 and i > 0) {
            i -= 1;
            switch (ops.items[i]) {
                .stars => |count| {
                    if (count <= remaining) {
                        remaining -= count;
                        continue;
                    }
                    break; // already fully covers what's left; nothing to convert
                },
                .literal => |lit| {
                    const len = lit.end - lit.start;
                    if (len <= remaining) {
                        ops.items[i] = .{ .stars = len };
                        remaining -= len;
                        continue;
                    }
                    const back = remaining;
                    const front_end = lit.end - back;
                    ops.items[i] = .{ .literal = .{ .start = lit.start, .end = front_end } };
                    try ops.insert(allocator, i + 1, .{ .stars = back });
                    break;
                },
            }
        }
    }

    /// Masks all patterns in `text` with `*`.
    ///
    /// Two passes: the first walks the automaton (DFA dispatch when built for
    /// this automaton, else the fail-link-walking `goTo`) and records an `Op`
    /// per match instead of writing bytes, so a rare match doesn't force output
    /// work for every byte in between. The second replays the op list to build
    /// the output in one pass of bulk memcpy/memset.
    ///
    /// `self.state` is premultiplied (`real_state * num_classes`) under DFA
    /// dispatch, a plain index otherwise; both agree on 0, so resetting or
    /// carrying it across calls needs no special-casing either way.
    ///
    /// The DFA branch also gates on `bigram_ok`/`one_byte_match` at the root: a
    /// byte that provably cannot start any match skips the `dfa_table`/`dfa_match`
    /// lookup entirely, which is a large win specifically for sparse corpora
    /// (few real matches spread through a lot of non-matching text) since most
    /// bytes never leave the root. See the gate's own comment for the
    /// correctness argument.
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
        const reminder: []const u8 = if (self.reminder) |r| r else &[_]u8{};
        const reminder_len = reminder.len;
        const input_len = reminder_len + args.text.len;

        // Pass 1: search. `pos` is absolute (reminder ++ text) position — only
        // `args.text` is walked here since `self.state`/`self.last_occur` already
        // reflect having consumed `reminder` in a previous call.
        var ops = try std.ArrayList(Op).initCapacity(self.allocator, 0);
        defer ops.deinit(self.allocator);
        // Absolute position up to which an `Op` already accounts for every byte
        // seen this call. Starts at 0, not `reminder_len`: the reminder is never
        // walked byte-by-byte, but a match's star-cap can still reach into it.
        var flushed_upto: usize = 0;
        const use_dfa = self.dfa_table.len > 0;
        for (args.text, 0..) |c, local_pos| {
            const pos = reminder_len + local_pos;
            var match_len: usize = 0;
            if (use_dfa) {
                // At the root, a byte that starts no pattern (or starts only
                // 2+-byte patterns whose second byte doesn't follow) can never
                // produce a match here, and always lands back at root either
                // way — so it's provably safe to skip straight to the next byte
                // without touching `dfa_table`/`dfa_match` at all. Guarded by
                // `one_byte_match` first: a 1-byte pattern match must never be
                // skipped, and `bigram_ok` alone has no way to record it (no
                // second byte to check). The last byte of a chunk always falls
                // through (can't peek ahead), which matters for streaming: the
                // reminder-depth bookkeeping needs `self.state` genuinely
                // updated for that byte, not skipped.
                if (self.state == 0 and !self.one_byte_match[c] and local_pos + 1 < args.text.len) {
                    const next_c = args.text[local_pos + 1];
                    if (!self.bigram_ok[(@as(usize, c) << 8) | next_c]) {
                        continue;
                    }
                }
                const idx = self.state + self.byte_class[c];
                self.state = self.dfa_table[idx];
                match_len = self.dfa_match[idx];
            } else {
                self.state = self.goTo(self.state, c);
                const node = self.nodes.items[self.state];
                match_len = if (node.id > 0) node.len else 0;
            }
            if (match_len == 0) continue;
            // This is the difference between the last character positions of the two patterns.
            const num = self.last_occur.overlapReminder(pos, match_len);
            self.last_occur.cum_len = if (num == MAX_INT) match_len else self.last_occur.cum_len + num;
            // Replace the last found pattern position and length.
            defer {
                self.last_occur.pos = @intCast(pos);
                self.last_occur.len = match_len;
            }
            // Difference between the pattern length and max number of stars.
            // If this difference is greater than 0 we need to limit the mask.
            // For overlapping patterns, we must account for the stars already printed by the previous pattern.
            var diff: usize = 0;
            if (self.last_occur.cum_len > args.max_stars) {
                diff = self.last_occur.cum_len - args.max_stars;
                diff = @min(num, diff);
            }
            var size = match_len - diff;
            if (num < MAX_INT) {
                if (self.last_occur.len >= args.max_stars) {
                    size = 0;
                } else {
                    size = @min(num, size);
                }
            }
            if (diff > 0 or size > 0) {
                // `pos + 1 - flushed_upto` equals `num` exactly (both the reminder
                // and every prior match set `flushed_upto` to their own `pos + 1`),
                // so `diff <= num` guarantees `trimTail` never reaches past this run.
                if (pos + 1 > flushed_upto) {
                    try ops.append(self.allocator, .{ .literal = .{ .start = flushed_upto, .end = pos + 1 } });
                }
                flushed_upto = pos + 1;
                if (diff > 0) trimTail(&ops, diff);
                if (size > 0) try ensureTailStars(&ops, self.allocator, size);
            }
        }

        // Pass 2: reconstruct. Copies a `[start, end)` span of the combined
        // reminder++text input, splitting at the reminder/text boundary as needed.
        var buf = try self.allocator.alloc(u8, input_len);
        var buf_len: usize = 0;
        const copyRange = struct {
            fn call(dst: []u8, dst_len: *usize, rem: []const u8, txt: []const u8, rlen: usize, start: usize, end: usize) void {
                if (end <= start) return;
                var s = start;
                if (s < rlen) {
                    const e = @min(end, rlen);
                    @memcpy(dst[dst_len.*..][0 .. e - s], rem[s..e]);
                    dst_len.* += e - s;
                    s = e;
                }
                if (s < end) {
                    @memcpy(dst[dst_len.*..][0 .. end - s], txt[s - rlen .. end - rlen]);
                    dst_len.* += end - s;
                }
            }
        }.call;

        for (ops.items) |op| {
            switch (op) {
                .literal => |lit| copyRange(buf, &buf_len, reminder, args.text, reminder_len, lit.start, lit.end),
                .stars => |count| {
                    @memset(buf[buf_len..][0..count], '*');
                    buf_len += count;
                },
            }
        }
        copyRange(buf, &buf_len, reminder, args.text, reminder_len, flushed_upto, input_len);

        var new_reminder_len: usize = 0;
        if (args.is_streaming) {
            self.reset_reminder();
            // Only the current state's trie depth of trailing bytes can still belong to
            // a future match, so retaining more would grow the reminder without bound
            // on inputs that keep the automaton away from the starting state.
            // Masking may have shrunk the buffer below that depth; retain what exists.
            // `self.state` is premultiplied under DFA dispatch, so recover the real node
            // index once here (once per call, not per byte, so the division is cheap).
            const real_state = if (use_dfa) self.state / self.num_classes else self.state;
            new_reminder_len = @min(self.nodes.items[real_state].depth, buf_len);
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

    /// Builds the byte-class-compressed, premultiplied DFA that `mask` dispatches
    /// through instead of `goTo`. Returns `false` (without allocating) if the
    /// projected table would exceed `DFA_MEMORY_CAP` — caller falls back to the
    /// classic `build`/`goTo` instead. Computes its own fail links via its own BFS;
    /// an automaton only ever uses one of `build` or `buildDfa`, never both (see
    /// `ss_build`).
    pub fn buildDfa(self: *Aho) !bool {
        // A byte is "relevant" if some node has a direct trie edge for it. Every
        // irrelevant byte behaves identically under `goTo` — no edge anywhere, so
        // it always falls back to state 0 — so one shared class for all of them
        // is exact, not an approximation.
        var used = [_]bool{false} ** 256;
        for (self.nodes.items) |node| {
            switch (node.edges) {
                .none => {},
                .one => |e| used[e.key] = true,
                .few => |few| {
                    for (0..few.count) |i| used[few.keys[i]] = true;
                },
                .dense => |dense| {
                    for (dense, 0..) |id, i| {
                        if (id != 0) used[i] = true;
                    }
                },
            }
        }

        // u16, not u8: `next_class` can reach 256 (every byte used, no catch-all),
        // which wraps silently in ReleaseFast as a u8 and defeats the cap check below.
        var representative = [_]u8{0} ** 256;
        var next_class: u16 = 0;
        for (0..256) |i| {
            if (used[i]) {
                self.byte_class[i] = @intCast(next_class);
                representative[next_class] = @intCast(i);
                next_class += 1;
            }
        }
        // Skip the catch-all class when all 256 bytes are used: nothing left to
        // catch, and reserving one anyway would index `representative` out of bounds.
        var has_unused = false;
        for (used) |u| {
            if (!u) {
                has_unused = true;
                break;
            }
        }
        if (has_unused) {
            const catch_all_class = next_class;
            for (0..256) |i| {
                if (!used[i]) {
                    self.byte_class[i] = @intCast(catch_all_class);
                    representative[catch_all_class] = @intCast(i);
                }
            }
            next_class += 1;
        }
        self.num_classes = next_class;
        const nc = self.num_classes;
        const num_states = self.total + 1;

        // Bail out before allocating anything if the compressed tables would still
        // exceed the memory cap for this pattern set.
        const entries = std.math.mul(usize, num_states, nc) catch return false;
        const bytes_needed = std.math.mul(usize, entries, 8) catch return false;
        if (bytes_needed > DFA_MEMORY_CAP) {
            return false;
        }

        // Classic BFS DFA construction, but walking classes (via one representative
        // raw byte per class) instead of all 256 raw byte values.
        const raw = try self.allocator.alloc(u32, num_states * nc);
        defer self.allocator.free(raw);

        for (0..nc) |cl| {
            raw[cl] = @intCast(self.nodes.items[0].child(representative[cl]) orelse 0);
        }

        var queue = try std.ArrayList(usize).initCapacity(self.allocator, 0);
        defer queue.deinit(self.allocator);
        try queue.append(self.allocator, 0);
        var head: usize = 0;
        while (head < queue.items.len) {
            const u = queue.items[head];
            head += 1;
            const fail_u = self.nodes.items[u].fail;
            for (0..nc) |cl| {
                const c = representative[cl];
                if (self.nodes.items[u].child(c)) |v| {
                    if (u != 0) {
                        self.nodes.items[v].fail = raw[fail_u * nc + cl];
                    }
                    raw[u * nc + cl] = @intCast(v);
                    try queue.append(self.allocator, v);
                } else if (u != 0) {
                    raw[u * nc + cl] = raw[fail_u * nc + cl];
                }
            }
        }

        self.dfa_table = try self.allocator.alloc(u32, num_states * nc);
        self.dfa_match = try self.allocator.alloc(u32, num_states * nc);
        const nc32: u32 = @intCast(nc);
        for (0..num_states * nc) |i| {
            const next_state = raw[i];
            self.dfa_table[i] = next_state * nc32;
            self.dfa_match[i] = self.nodes.items[next_state].len;
        }
        return true;
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
