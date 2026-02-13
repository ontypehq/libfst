const std = @import("std");
const arc_mod = @import("../arc.zig");
const mutable_fst_mod = @import("../mutable-fst.zig");

const StateId = arc_mod.StateId;
const no_state = arc_mod.no_state;
const Allocator = std.mem.Allocator;

/// Remove non-accessible and non-coaccessible states.
///
/// Returns a new FST containing only states that are:
///   1. Reachable from the start state (accessible)
///   2. Can reach at least one final state (coaccessible)
///
/// The result preserves arc labels, weights, and final weights.
/// State IDs are renumbered contiguously from 0.
pub fn connect(comptime W: type, allocator: Allocator, fst: *const mutable_fst_mod.MutableFst(W)) !mutable_fst_mod.MutableFst(W) {
    const n = fst.numStates();
    if (fst.start() == no_state or n == 0) {
        return mutable_fst_mod.MutableFst(W).init(allocator);
    }

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Step 1: Forward BFS — find accessible states
    const accessible = try arena.alloc(bool, n);
    @memset(accessible, false);
    {
        var queue = std.ArrayListUnmanaged(StateId).empty;
        defer queue.deinit(arena);
        accessible[fst.start()] = true;
        try queue.append(arena, fst.start());
        while (queue.items.len > 0) {
            const s = queue.orderedRemove(0);
            for (fst.arcs(s)) |a| {
                if (a.nextstate < n and !accessible[a.nextstate]) {
                    accessible[a.nextstate] = true;
                    try queue.append(arena, a.nextstate);
                }
            }
        }
    }

    // Step 2: Build reverse adjacency list
    var rev = try arena.alloc(std.ArrayListUnmanaged(StateId), n);
    for (0..n) |i| rev[i] = .empty;
    for (0..n) |i| {
        const s: StateId = @intCast(i);
        for (fst.arcs(s)) |a| {
            if (a.nextstate < n) {
                try rev[a.nextstate].append(arena, s);
            }
        }
    }

    // Step 3: Backward BFS from final states — find coaccessible states
    const coaccessible = try arena.alloc(bool, n);
    @memset(coaccessible, false);
    {
        var queue = std.ArrayListUnmanaged(StateId).empty;
        defer queue.deinit(arena);
        for (0..n) |i| {
            const s: StateId = @intCast(i);
            if (fst.isFinal(s)) {
                coaccessible[s] = true;
                try queue.append(arena, s);
            }
        }
        while (queue.items.len > 0) {
            const s = queue.orderedRemove(0);
            for (rev[s].items) |pred| {
                if (!coaccessible[pred]) {
                    coaccessible[pred] = true;
                    try queue.append(arena, pred);
                }
            }
        }
    }

    // Step 4: Build state mapping (old → new) for states that are both accessible and coaccessible
    const old_to_new = try arena.alloc(StateId, n);
    @memset(old_to_new, no_state);
    var new_count: u32 = 0;
    for (0..n) |i| {
        if (accessible[i] and coaccessible[i]) {
            old_to_new[i] = new_count;
            new_count += 1;
        }
    }

    // If start is not connected, return empty
    if (old_to_new[fst.start()] == no_state) {
        return mutable_fst_mod.MutableFst(W).init(allocator);
    }

    // Step 5: Build new FST
    const A = arc_mod.Arc(W);
    var result = mutable_fst_mod.MutableFst(W).init(allocator);
    errdefer result.deinit();

    try result.addStates(new_count);
    result.setStart(old_to_new[fst.start()]);

    for (0..n) |i| {
        const old_s: StateId = @intCast(i);
        const new_s = old_to_new[i];
        if (new_s == no_state) continue;

        if (fst.isFinal(old_s)) {
            result.setFinal(new_s, fst.finalWeight(old_s));
        }

        for (fst.arcs(old_s)) |a| {
            const new_next = old_to_new[a.nextstate];
            if (new_next != no_state) {
                try result.addArc(new_s, A.init(a.ilabel, a.olabel, a.weight, new_next));
            }
        }
    }

    return result;
}

// ── Tests ──

test "connect: removes dead states" {
    const TW = @import("../weight.zig").TropicalWeight;
    const TA = arc_mod.Arc(TW);
    const allocator = std.testing.allocator;

    // 0 → 1 (a) → 2 (final)
    // 0 → 3 (b) → dead end (not final, no outgoing)
    var fst = mutable_fst_mod.MutableFst(TW).init(allocator);
    defer fst.deinit();
    try fst.addStates(4);
    fst.setStart(0);
    fst.setFinal(2, TW.one);
    try fst.addArc(0, TA.init(1, 1, TW.one, 1));
    try fst.addArc(1, TA.init(2, 2, TW.one, 2));
    try fst.addArc(0, TA.init(3, 3, TW.one, 3)); // dead end

    var result = try connect(TW, allocator, &fst);
    defer result.deinit();

    // Should only have 3 states (0, 1, 2) — state 3 removed
    try std.testing.expectEqual(@as(u32, 3), result.numStates());
    try std.testing.expect(result.start() != no_state);
}

test "connect: preserves fully connected FST" {
    const TW = @import("../weight.zig").TropicalWeight;
    const TA = arc_mod.Arc(TW);
    const allocator = std.testing.allocator;

    var fst = mutable_fst_mod.MutableFst(TW).init(allocator);
    defer fst.deinit();
    try fst.addStates(2);
    fst.setStart(0);
    fst.setFinal(1, TW.one);
    try fst.addArc(0, TA.init(1, 1, TW.one, 1));

    var result = try connect(TW, allocator, &fst);
    defer result.deinit();

    try std.testing.expectEqual(@as(u32, 2), result.numStates());
}

test "connect: empty FST" {
    const TW = @import("../weight.zig").TropicalWeight;
    const allocator = std.testing.allocator;

    var fst = mutable_fst_mod.MutableFst(TW).init(allocator);
    defer fst.deinit();

    var result = try connect(TW, allocator, &fst);
    defer result.deinit();

    try std.testing.expectEqual(no_state, result.start());
}
