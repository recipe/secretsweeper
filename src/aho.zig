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
    /// Length of the longest pattern that ends at this node.
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

/// One maximal run of overlapping matches, in absolute positions of a call's
/// input (`reminder ++ text`). Regions never overlap each other and are kept
/// in increasing order. A region is masked as `min(end - start, max_stars)`
/// stars, `emitted` of which an earlier streaming call already wrote out
/// (see `cut` in `mask`). `start` is negative for a region that began before
/// the current input, i.e. inside output that is already emitted.
const Region = struct {
    start: isize,
    end: usize,
    emitted: usize = 0,

    /// Stars still owed for the region's prefix `[start, upto)`.
    fn starsUpTo(self: Region, upto: usize, max_stars: u64) usize {
        const len: u64 = @intCast(@as(isize, @intCast(upto)) - self.start);
        const total: usize = @intCast(@min(len, max_stars));
        return total -| self.emitted;
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

    /// Streaming mode: the trailing `depth(state)` input bytes of everything seen
    /// so far, verbatim. Only these can still belong to a future match, and they
    /// are kept unmasked because a later match may extend a pending region over
    /// them, which changes how many stars the region gets.
    reminder: ?[]u8 = null,
    /// Streaming mode: regions inside `reminder` (positions relative to its first
    /// byte) whose final extent is not decided yet.
    pending: std.ArrayList(Region),
    /// `max_stars` of the last streaming call, so `renderReminder` masks `pending`
    /// consistently with the output already emitted.
    pending_max_stars: u64 = 0,
    /// Owned buffer behind `ss_get_reminder`'s pointer-returning C API; freed by
    /// the next call that changes the streaming state.
    rendered_reminder: ?[]u8 = null,
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
            .pending = try std.ArrayList(Region).initCapacity(allocator, 0),
        };
    }

    /// Ends a stream: drops the reminder and everything pending, and returns the
    /// automaton to its starting state.
    pub fn reset_reminder(self: *Aho) void {
        if (self.reminder) |reminder| {
            self.allocator.free(reminder);
            self.reminder = null;
        }
        self.pending.clearRetainingCapacity();
        self.freeRenderedReminder();
        self.state = 0;
    }

    fn freeRenderedReminder(self: *Aho) void {
        if (self.rendered_reminder) |rendered| {
            self.allocator.free(rendered);
            self.rendered_reminder = null;
        }
    }

    pub fn deinit(self: *Aho) void {
        self.reset_reminder();
        self.pending.deinit(self.allocator);
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

    /// Dictionary-suffix output: a non-terminal node reports the longest pattern
    /// ending at its fail node, so a short pattern is still found while the
    /// automaton sits inside a longer pattern's trie path (e.g. "ring" at the
    /// "boring" node of "boring day"). A terminal's own pattern is always at
    /// least as long as any suffix pattern, so it keeps its own `len`. Called in
    /// BFS order right after `fail` is set, so the fail node is already final.
    fn inheritOutput(self: *Aho, v: usize) void {
        const node = &self.nodes.items[v];
        if (node.id == 0) {
            node.len = self.nodes.items[node.fail].len;
        }
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
                    self.inheritOutput(v);
                    try queue.append(self.allocator, v);
                }
            }
        }
    }

    /// Copies the `[start, end)` span of the combined `reminder ++ text` input.
    fn copyInput(dst: []u8, dst_len: *usize, reminder: []const u8, text: []const u8, start: usize, end: usize) void {
        if (end <= start) return;
        var s = start;
        const rlen = reminder.len;
        if (s < rlen) {
            const e = @min(end, rlen);
            @memcpy(dst[dst_len.*..][0 .. e - s], reminder[s..e]);
            dst_len.* += e - s;
            s = e;
        }
        if (s < end) {
            @memcpy(dst[dst_len.*..][0 .. end - s], text[s - rlen .. end - rlen]);
            dst_len.* += end - s;
        }
    }

    /// Writes the output for the input prefix `[0, cut)`: literal bytes outside
    /// regions and each region's owed stars. A region reaching past `cut` gets
    /// the stars owed for its part before `cut` and the rest is appended to
    /// `self.pending`, rebased so that `cut` becomes position 0. That prefix
    /// never needs retracting later: `min(len, max_stars)` only grows with the
    /// region, and its stars are placed leftmost.
    fn render(self: *Aho, regions: []const Region, reminder: []const u8, text: []const u8, cut: usize, max_stars: u64) ![]u8 {
        // Every star stands for a distinct input byte before `cut`, so `cut`
        // bounds the output.
        var buf = try self.allocator.alloc(u8, cut);
        errdefer self.allocator.free(buf);
        var buf_len: usize = 0;
        var covered: usize = 0;
        const cut_i: isize = @intCast(cut);
        for (regions) |r| {
            const lit_end: usize = @intCast(@min(@max(r.start, 0), cut_i));
            copyInput(buf, &buf_len, reminder, text, covered, lit_end);
            if (r.end <= cut) {
                const n = r.starsUpTo(r.end, max_stars);
                @memset(buf[buf_len..][0..n], '*');
                buf_len += n;
                covered = r.end;
                continue;
            }
            // Nothing is owed yet for a region that starts at or after the cut.
            const upto: usize = if (r.start < cut_i) cut else @intCast(r.start);
            const n = r.starsUpTo(upto, max_stars);
            @memset(buf[buf_len..][0..n], '*');
            buf_len += n;
            try self.pending.append(self.allocator, .{
                .start = r.start - cut_i,
                .end = r.end - cut,
                .emitted = r.emitted + n,
            });
            covered = cut;
        }
        copyInput(buf, &buf_len, reminder, text, covered, cut);
        if (buf_len < cut) {
            buf = try self.allocator.realloc(buf, buf_len);
        }
        return buf;
    }

    /// The output still owed for the reminder if the stream ended now: its bytes
    /// with the pending regions masked. Leaves the streaming state untouched.
    pub fn renderReminder(self: *Aho) ![]u8 {
        const reminder: []const u8 = self.reminder orelse "";
        // Every pending region ends inside the reminder, so nothing gets re-queued.
        return self.render(self.pending.items, reminder, "", reminder.len, self.pending_max_stars);
    }

    /// `renderReminder` into a buffer the automaton owns, for the pointer-returning
    /// C API. Valid until the next `mask`/`reset_reminder`/`deinit`.
    pub fn renderReminderCached(self: *Aho) ![]const u8 {
        self.freeRenderedReminder();
        const rendered = try self.renderReminder();
        self.rendered_reminder = rendered;
        return rendered;
    }

    /// Masks all patterns in `text` with `*`.
    ///
    /// Two passes: the first walks the automaton (DFA dispatch when built for
    /// this automaton, else the fail-link-walking `goTo`) and records the match
    /// regions instead of writing bytes, so a rare match doesn't force output
    /// work for every byte in between. The second replays the regions to build
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
        }
        self.freeRenderedReminder();
        const reminder: []const u8 = self.reminder orelse "";
        const reminder_len = reminder.len;
        const input_len = reminder_len + args.text.len;

        // Pass 1: search. Only `args.text` is walked: `self.state` already
        // reflects having consumed `reminder` in a previous call, and `regions`
        // starts from what that call left undecided.
        var regions = try std.ArrayList(Region).initCapacity(self.allocator, self.pending.items.len);
        defer regions.deinit(self.allocator);
        regions.appendSliceAssumeCapacity(self.pending.items);
        self.pending.clearRetainingCapacity();

        const use_dfa = self.dfa_table.len > 0;
        for (args.text, 0..) |c, local_pos| {
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
                match_len = self.nodes.items[self.state].len;
            }
            if (match_len == 0) continue;
            const end = reminder_len + local_pos + 1;
            // The reminder holds exactly the state's depth of bytes, so a match
            // never starts before this call's input; saturate rather than trust it.
            var start: isize = @intCast(end -| match_len);
            var emitted: usize = 0;
            // A match can start before earlier regions: a shorter pattern that is
            // a suffix of a longer one's prefix is reported first (see
            // `inheritOutput`), then the longer one completes — "ash", then
            // "masher" in "smasher". Merge every region it overlaps, peeling
            // from the tail; adjacent regions stay separate.
            while (regions.items.len > 0) {
                const last = regions.items[regions.items.len - 1];
                if (@as(isize, @intCast(last.end)) <= start) break;
                start = @min(start, last.start);
                emitted += last.emitted;
                regions.shrinkRetainingCapacity(regions.items.len - 1);
            }
            try regions.append(self.allocator, .{ .start = start, .end = end, .emitted = emitted });
        }

        // Pass 2: output. In streaming mode only the current state's trie depth
        // of trailing bytes can still belong to a future match (anything earlier
        // would need a deeper state), so those bytes and any region reaching
        // into them stay pending; retaining more would grow the reminder without
        // bound on inputs that keep the automaton away from the starting state.
        // `self.state` is premultiplied under DFA dispatch, so recover the real
        // node index once here.
        var cut = input_len;
        if (args.is_streaming) {
            const real_state = if (use_dfa) self.state / self.num_classes else self.state;
            cut = input_len -| self.nodes.items[real_state].depth;
        }
        const out = try self.render(regions.items, reminder, args.text, cut, args.max_stars);
        if (args.is_streaming) {
            errdefer self.allocator.free(out);
            var kept: ?[]u8 = null;
            if (input_len > cut) {
                const buf = try self.allocator.alloc(u8, input_len - cut);
                var buf_len: usize = 0;
                copyInput(buf, &buf_len, reminder, args.text, cut, input_len);
                kept = buf;
            }
            if (self.reminder) |old| self.allocator.free(old);
            self.reminder = kept;
            self.pending_max_stars = args.max_stars;
        }
        return out;
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
                    self.inheritOutput(v);
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

/// The output still owed for the stream, i.e. what `consume_reminder` returns.
fn expectReminder(ac: *Aho, expected: []const u8) !void {
    const rendered = try ac.renderReminder();
    defer ac.allocator.free(rendered);
    try testing.expectEqualStrings(expected, rendered);
}

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
        try expectReminder(&ac, "");
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
        try expectReminder(&ac, expected_reminder[i]);
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
        try expectReminder(&ac, expected_reminder[i]);
    }
    try expectReminder(&ac, "*");
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
        try expectReminder(&ac, "a");
    }

    // The retained "a" combines with a "b" in the next chunk into a match.
    // The stars are withheld while a following pattern could still overlap them.
    const masked = try ac.mask(.{ .text = "b", .is_streaming = true });
    defer allocator.free(masked);
    try testing.expectEqualStrings("", masked);
    try expectReminder(&ac, "**");

    const rest = try ac.mask(.{ .text = "c", .is_streaming = true });
    defer allocator.free(rest);
    try testing.expectEqualStrings("**c", rest);
    try expectReminder(&ac, "");
}

test "streaming rebases the last match when the reminder shrinks" {
    for ([_]bool{ false, true }) |dfa| {
        var ac = try Aho.init(testing.allocator);
        defer ac.deinit();
        _ = try ac.insert("a");
        _ = try ac.insert("baa");
        if (dfa) {
            try testing.expect(try ac.buildDfa());
        } else {
            try ac.build();
        }
        for ([_][]const u8{ "ba", "", "a", "", "a" }) |chunk| {
            const masked = try ac.mask(.{ .text = chunk, .max_stars = 0, .is_streaming = true });
            defer testing.allocator.free(masked);
            try testing.expectEqualStrings("", masked);
        }
        try expectReminder(&ac, "");
    }
}

test "a shorter pattern ending inside a longer pattern's trie path is found" {
    for ([_]bool{ false, true }) |dfa| {
        var ac = try Aho.init(testing.allocator);
        defer ac.deinit();
        _ = try ac.insert("boring day");
        _ = try ac.insert("ring");
        _ = try ac.insert("abcd");
        _ = try ac.insert("bc");
        if (dfa) {
            try testing.expect(try ac.buildDfa());
        } else {
            try ac.build();
        }
        const masked = try ac.mask(.{ .text = "boring data abcx" });
        defer testing.allocator.free(masked);
        try testing.expectEqualStrings("bo**** data a**x", masked);
    }
}

test "a later match may start before an earlier one, across chunks and regions" {
    for ([_]bool{ false, true }) |dfa| {
        for ([_]u64{ 15, 1, 0 }) |limit| {
            var ac = try Aho.init(testing.allocator);
            defer ac.deinit();
            _ = try ac.insert("ab");
            _ = try ac.insert("c");
            _ = try ac.insert("abcd");
            _ = try ac.insert("bcx");
            if (dfa) {
                try testing.expect(try ac.buildDfa());
            } else {
                try ac.build();
            }
            // "ab" and the adjacent "c" are two regions; "abcd" then swallows both.
            const one_shot = try ac.mask(.{ .text = "zabcdz", .max_stars = limit });
            defer testing.allocator.free(one_shot);
            const stars: []const u8 = "****";
            var expected = std.ArrayList(u8).empty;
            defer expected.deinit(testing.allocator);
            try expected.append(testing.allocator, 'z');
            try expected.appendSlice(testing.allocator, stars[0..@min(4, limit)]);
            try expected.append(testing.allocator, 'z');
            try testing.expectEqualStrings(expected.items, one_shot);

            // The same, streamed one byte at a time: "ab" then "c" are masked
            // provisionally while "abcd" (or "bcx") could still overlap them.
            var out = std.ArrayList(u8).empty;
            defer out.deinit(testing.allocator);
            for ("zabcdz") |byte| {
                const chunk = try ac.mask(.{ .text = &[_]u8{byte}, .max_stars = limit, .is_streaming = true });
                defer testing.allocator.free(chunk);
                try out.appendSlice(testing.allocator, chunk);
            }
            const rest = try ac.renderReminder();
            defer testing.allocator.free(rest);
            try out.appendSlice(testing.allocator, rest);
            try testing.expectEqualStrings(expected.items, out.items);
            ac.reset_reminder();

            // A region straddling the cut: "abc" is decided, but "bcx" could
            // still extend over "bc", so only the stars for "a" are emitted.
            const head = try ac.mask(.{ .text = "abc", .max_stars = limit, .is_streaming = true });
            defer testing.allocator.free(head);
            try testing.expectEqualStrings("", head);
            const tail = try ac.mask(.{ .text = "x", .max_stars = limit, .is_streaming = true });
            defer testing.allocator.free(tail);
            try testing.expectEqualStrings(stars[0..@min(1, limit)], tail);
            try expectReminder(&ac, stars[0..@min(4, limit) -| @min(1, limit)]);
        }
    }
}
