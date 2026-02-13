const std = @import("std");
const weight_mod = @import("weight.zig");
const arc_mod = @import("arc.zig");

const Label = arc_mod.Label;
const StateId = arc_mod.StateId;
const no_state = arc_mod.no_state;
const Allocator = std.mem.Allocator;

/// Mutable state within a MutableFst.
fn MutableState(comptime W: type) type {
    return struct {
        final_weight: W,
        arcs: std.ArrayListUnmanaged(arc_mod.Arc(W)),

        const Self = @This();

        fn init() Self {
            return .{
                .final_weight = W.zero,
                .arcs = .empty,
            };
        }

        fn deinit(self: *Self, allocator: Allocator) void {
            self.arcs.deinit(allocator);
        }

        fn clone(self: *const Self, allocator: Allocator) !Self {
            return .{
                .final_weight = self.final_weight,
                .arcs = try self.arcs.clone(allocator),
            };
        }
    };
}

/// Mutable FST for build-time construction.
/// All operations and algorithms work on this type.
/// Call `freeze()` to produce an immutable `Fst` for runtime use.
///
/// Safety: every structural mutation increments `generation`. Code that
/// holds slices obtained from `arcs()` across mutations can use
/// `checkGeneration()` in debug mode to detect invalidation.
pub fn MutableFst(comptime W: type) type {
    const A = arc_mod.Arc(W);

    return struct {
        allocator: Allocator,
        states: std.ArrayListUnmanaged(MutableState(W)),
        start_state: StateId,
        /// Monotonically increasing counter; bumped on every structural mutation.
        /// Callers may snapshot this value and later assert it hasn't changed
        /// to guard against use of invalidated slices.
        generation: u64,

        const Self = @This();

        pub fn init(allocator: Allocator) Self {
            return .{
                .allocator = allocator,
                .states = .empty,
                .start_state = no_state,
                .generation = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.states.items) |*s| {
                s.deinit(self.allocator);
            }
            self.states.deinit(self.allocator);
        }

        // ── Generation guard ──

        /// Snapshot the current generation. Pass the returned value to
        /// `checkGeneration()` after performing reads to assert that no
        /// mutation occurred in between.
        pub fn gen(self: *const Self) u64 {
            return self.generation;
        }

        /// In debug/safe builds, asserts that `snapshot` still matches the
        /// current generation. In release builds this is a no-op.
        pub fn checkGeneration(self: *const Self, snapshot: u64) void {
            std.debug.assert(snapshot == self.generation);
        }

        inline fn bump(self: *Self) void {
            self.generation +%= 1;
        }

        // ── Mutation (each bumps generation) ──

        pub fn addState(self: *Self) !StateId {
            const id: StateId = @intCast(self.states.items.len);
            try self.states.append(self.allocator, MutableState(W).init());
            self.bump();
            return id;
        }

        pub fn addStates(self: *Self, n: usize) !void {
            try self.states.ensureUnusedCapacity(self.allocator, n);
            for (0..n) |_| {
                self.states.appendAssumeCapacity(MutableState(W).init());
            }
            if (n > 0) self.bump();
        }

        pub fn setStart(self: *Self, s: StateId) void {
            self.start_state = s;
            // setStart doesn't invalidate arc slices, but we bump anyway
            // for consistency so generation == "number of mutations".
            self.bump();
        }

        pub fn setFinal(self: *Self, s: StateId, w: W) void {
            self.states.items[s].final_weight = w;
            // Doesn't invalidate arc slices, but keeps generation consistent.
            self.bump();
        }

        pub fn addArc(self: *Self, src: StateId, a: A) !void {
            try self.states.items[src].arcs.append(self.allocator, a);
            self.bump();
        }

        pub fn deleteArcs(self: *Self, s: StateId) void {
            self.states.items[s].arcs.clearRetainingCapacity();
            self.bump();
        }

        pub fn deleteStates(self: *Self) void {
            for (self.states.items) |*s| {
                s.deinit(self.allocator);
            }
            self.states.clearRetainingCapacity();
            self.start_state = no_state;
            self.bump();
        }

        pub fn sortArcs(self: *Self, s: StateId) void {
            std.mem.sort(A, self.states.items[s].arcs.items, {}, A.compareByIlabel);
            self.bump();
        }

        pub fn sortAllArcs(self: *Self) void {
            for (0..self.states.items.len) |i| {
                std.mem.sort(A, self.states.items[i].arcs.items, {}, A.compareByIlabel);
            }
            self.bump();
        }

        // ── Query ──

        pub fn start(self: *const Self) StateId {
            return self.start_state;
        }

        pub fn finalWeight(self: *const Self, s: StateId) W {
            return self.states.items[s].final_weight;
        }

        pub fn isFinal(self: *const Self, s: StateId) bool {
            return !self.states.items[s].final_weight.isZero();
        }

        pub fn numStates(self: *const Self) usize {
            return self.states.items.len;
        }

        pub fn numArcs(self: *const Self, s: StateId) usize {
            return self.states.items[s].arcs.items.len;
        }

        /// Return a slice of arcs for state `s`.
        ///
        /// WARNING: this slice is invalidated by any mutation on the SAME
        /// state's arc list (addArc, deleteArcs, sortArcs). Use
        /// `gen()` / `checkGeneration()` to guard against this in debug
        /// builds.
        pub fn arcs(self: *const Self, s: StateId) []const A {
            return self.states.items[s].arcs.items;
        }

        pub fn arcsMut(self: *Self, s: StateId) []A {
            return self.states.items[s].arcs.items;
        }

        pub fn totalArcs(self: *const Self) usize {
            var total: usize = 0;
            for (self.states.items) |s| {
                total += s.arcs.items.len;
            }
            return total;
        }

        // ── Lifecycle ──

        pub fn clone(self: *const Self, allocator: Allocator) !Self {
            var new_states = try std.ArrayListUnmanaged(MutableState(W)).initCapacity(allocator, self.states.items.len);
            errdefer {
                for (new_states.items) |*s| {
                    s.deinit(allocator);
                }
                new_states.deinit(allocator);
            }
            for (self.states.items) |*s| {
                new_states.appendAssumeCapacity(try s.clone(allocator));
            }
            return .{
                .allocator = allocator,
                .states = new_states,
                .start_state = self.start_state,
                .generation = 0, // fresh clone starts at gen 0
            };
        }

        pub fn remapStates(self: *Self, mapping: []const StateId) !void {
            const old_states = self.states;
            var new_states = try std.ArrayListUnmanaged(MutableState(W)).initCapacity(self.allocator, old_states.items.len);
            errdefer {
                for (new_states.items) |*s| {
                    s.deinit(self.allocator);
                }
                new_states.deinit(self.allocator);
            }

            var max_new: StateId = 0;
            for (mapping) |new_id| {
                if (new_id != no_state and new_id >= max_new) {
                    max_new = new_id + 1;
                }
            }

            new_states.items.len = max_new;
            for (new_states.items) |*s| {
                s.* = MutableState(W).init();
            }

            // Track which new slots already have a state assigned
            const assigned = try self.allocator.alloc(bool, max_new);
            defer self.allocator.free(assigned);
            @memset(assigned, false);

            for (old_states.items, 0..) |*old_s, old_i| {
                const new_id = mapping[old_i];
                if (new_id == no_state) {
                    var s_copy = old_s.*;
                    s_copy.deinit(self.allocator);
                    continue;
                }
                if (assigned[new_id]) {
                    // Slot already occupied by an equivalent state — free duplicate
                    var s_copy = old_s.*;
                    s_copy.deinit(self.allocator);
                    continue;
                }
                assigned[new_id] = true;
                new_states.items[new_id] = old_s.*;
                for (new_states.items[new_id].arcs.items) |*a| {
                    if (a.nextstate != no_state and a.nextstate < mapping.len) {
                        a.nextstate = mapping[a.nextstate];
                    }
                }
            }

            var old = old_states;
            old.deinit(self.allocator);
            self.states = new_states;

            if (self.start_state != no_state and self.start_state < mapping.len) {
                self.start_state = mapping[self.start_state];
            }
            self.bump();
        }
    };
}

pub const StdMutableFst = MutableFst(weight_mod.TropicalWeight);
pub const LogMutableFst = MutableFst(weight_mod.LogWeight);

// ── Tests ──

test "mutable-fst: basic construction" {
    const W = weight_mod.TropicalWeight;
    const A = arc_mod.Arc(W);
    const allocator = std.testing.allocator;

    var fst = MutableFst(W).init(allocator);
    defer fst.deinit();

    const s0 = try fst.addState();
    const s1 = try fst.addState();
    const s2 = try fst.addState();

    fst.setStart(s0);
    fst.setFinal(s2, W.one);

    try fst.addArc(s0, A.init(1, 1, W.init(0.5), s1));
    try fst.addArc(s1, A.init(2, 2, W.init(1.0), s2));

    try std.testing.expectEqual(@as(usize, 3), fst.numStates());
    try std.testing.expectEqual(s0, fst.start());
    try std.testing.expect(fst.isFinal(s2));
    try std.testing.expect(!fst.isFinal(s0));
    try std.testing.expectEqual(@as(usize, 1), fst.numArcs(s0));
    try std.testing.expectEqual(@as(usize, 1), fst.numArcs(s1));
    try std.testing.expectEqual(@as(usize, 0), fst.numArcs(s2));
}

test "mutable-fst: generation counter" {
    const W = weight_mod.TropicalWeight;
    const A = arc_mod.Arc(W);
    const allocator = std.testing.allocator;

    var fst = MutableFst(W).init(allocator);
    defer fst.deinit();

    try std.testing.expectEqual(@as(u64, 0), fst.gen());

    _ = try fst.addState();
    const g1 = fst.gen();
    try std.testing.expect(g1 > 0);

    _ = try fst.addState();
    const g2 = fst.gen();
    try std.testing.expect(g2 > g1);

    // Snapshot before mutation
    const snapshot = fst.gen();
    fst.checkGeneration(snapshot); // should not panic

    try fst.addArc(0, A.init(1, 1, W.one, 1));
    // snapshot is now stale — checkGeneration would assert in debug
    try std.testing.expect(fst.gen() != snapshot);
}

test "mutable-fst: delete arcs" {
    const W = weight_mod.TropicalWeight;
    const A = arc_mod.Arc(W);
    const allocator = std.testing.allocator;

    var fst = MutableFst(W).init(allocator);
    defer fst.deinit();

    const s0 = try fst.addState();
    const s1 = try fst.addState();
    try fst.addArc(s0, A.init(1, 1, W.one, s1));
    try fst.addArc(s0, A.init(2, 2, W.one, s1));

    try std.testing.expectEqual(@as(usize, 2), fst.numArcs(s0));
    fst.deleteArcs(s0);
    try std.testing.expectEqual(@as(usize, 0), fst.numArcs(s0));
}

test "mutable-fst: delete states" {
    const W = weight_mod.TropicalWeight;
    const allocator = std.testing.allocator;

    var fst = MutableFst(W).init(allocator);
    defer fst.deinit();

    _ = try fst.addState();
    _ = try fst.addState();
    try std.testing.expectEqual(@as(usize, 2), fst.numStates());

    fst.deleteStates();
    try std.testing.expectEqual(@as(usize, 0), fst.numStates());
    try std.testing.expectEqual(no_state, fst.start());
}

test "mutable-fst: clone" {
    const W = weight_mod.TropicalWeight;
    const A = arc_mod.Arc(W);
    const allocator = std.testing.allocator;

    var fst = MutableFst(W).init(allocator);
    defer fst.deinit();

    const s0 = try fst.addState();
    const s1 = try fst.addState();
    fst.setStart(s0);
    fst.setFinal(s1, W.one);
    try fst.addArc(s0, A.init(1, 2, W.init(3.0), s1));

    var fst2 = try fst.clone(allocator);
    defer fst2.deinit();

    try std.testing.expectEqual(@as(usize, 2), fst2.numStates());
    try std.testing.expectEqual(s0, fst2.start());
    try std.testing.expect(fst2.isFinal(s1));
    try std.testing.expectEqual(@as(usize, 1), fst2.numArcs(s0));
    try std.testing.expectEqual(@as(u64, 0), fst2.gen()); // fresh clone

    const a = fst2.arcs(s0)[0];
    try std.testing.expectEqual(@as(Label, 1), a.ilabel);
    try std.testing.expectEqual(@as(Label, 2), a.olabel);
}

test "mutable-fst: sort arcs" {
    const W = weight_mod.TropicalWeight;
    const A = arc_mod.Arc(W);
    const allocator = std.testing.allocator;

    var fst = MutableFst(W).init(allocator);
    defer fst.deinit();

    const s0 = try fst.addState();
    const s1 = try fst.addState();
    try fst.addArc(s0, A.init(3, 0, W.one, s1));
    try fst.addArc(s0, A.init(1, 0, W.one, s1));
    try fst.addArc(s0, A.init(2, 0, W.one, s1));

    fst.sortArcs(s0);
    const sorted = fst.arcs(s0);
    try std.testing.expectEqual(@as(Label, 1), sorted[0].ilabel);
    try std.testing.expectEqual(@as(Label, 2), sorted[1].ilabel);
    try std.testing.expectEqual(@as(Label, 3), sorted[2].ilabel);
}

test "mutable-fst: totalArcs" {
    const W = weight_mod.TropicalWeight;
    const A = arc_mod.Arc(W);
    const allocator = std.testing.allocator;

    var fst = MutableFst(W).init(allocator);
    defer fst.deinit();

    const s0 = try fst.addState();
    const s1 = try fst.addState();
    try fst.addArc(s0, A.init(1, 1, W.one, s1));
    try fst.addArc(s0, A.init(2, 2, W.one, s1));
    try fst.addArc(s1, A.init(3, 3, W.one, s0));

    try std.testing.expectEqual(@as(usize, 3), fst.totalArcs());
}
