const std = @import("std");
const arc_mod = @import("../arc.zig");
const mutable_fst_mod = @import("../mutable-fst.zig");

const StateId = arc_mod.StateId;
const no_state = arc_mod.no_state;
const Allocator = std.mem.Allocator;

/// Find the single shortest path through a weighted FST.
/// Uses Dijkstra-like search with deterministic tie-breaking:
///   1. Compare weights (lower is better for tropical)
///   2. If equal, compare state IDs ascending
///
/// This API accepts `n` for compatibility with the C surface, but only
/// `n == 1` is supported. For `n > 1`, returns `error.UnsupportedNShortest`.
///
/// Returns a new MutableFst containing the best path as a linear chain.
pub fn shortestPath(comptime W: type, allocator: Allocator, fst: *const mutable_fst_mod.MutableFst(W), n: u32) !mutable_fst_mod.MutableFst(W) {
    const A = arc_mod.Arc(W);

    if (fst.start() == no_state or n == 0) {
        return mutable_fst_mod.MutableFst(W).init(allocator);
    }
    if (n != 1) return error.UnsupportedNShortest;

    // Arena for all temporaries — freed in bulk on return
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Dijkstra's algorithm to find shortest distances.
    const num_states = fst.numStates();

    // Distance to each state
    var dist = try arena.alloc(W, num_states);
    for (dist) |*d| d.* = W.zero;
    dist[fst.start()] = W.one;

    // Best incoming arc for backtracking
    const BackPtr = struct {
        prev_state: StateId,
        arc_idx: u32,
    };
    var back = try arena.alloc(?BackPtr, num_states);
    @memset(back, null);

    var settled = try arena.alloc(bool, num_states);
    @memset(settled, false);

    const QueueItem = struct {
        state: StateId,
        dist: W,
    };
    const queueCompare = struct {
        fn call(_: void, a: QueueItem, b: QueueItem) std.math.Order {
            const by_dist = W.compare(a.dist, b.dist);
            if (by_dist != .eq) return by_dist;
            return std.math.order(a.state, b.state);
        }
    }.call;
    var queue = std.PriorityQueue(QueueItem, void, queueCompare).init(arena, {});
    try queue.add(.{ .state = fst.start(), .dist = W.one });

    while (queue.removeOrNull()) |item| {
        const s = item.state;
        if (settled[s]) continue;
        if (W.compare(item.dist, dist[s]) != .eq) continue; // stale queue entry
        settled[s] = true;

        for (fst.arcs(s), 0..) |a, ai| {
            const next = a.nextstate;
            const new_dist = W.times(dist[s], a.weight);
            const old_dist = dist[next];
            const by_dist = W.compare(new_dist, old_dist);
            const prev_state = if (back[next]) |bp| bp.prev_state else no_state;
            const better_tie = by_dist == .eq and (prev_state == no_state or s < prev_state);

            if (old_dist.isZero() or by_dist == .lt or better_tie) {
                dist[next] = new_dist;
                back[next] = .{ .prev_state = s, .arc_idx = @intCast(ai) };
                if (!settled[next]) {
                    try queue.add(.{ .state = next, .dist = new_dist });
                }
            }
        }
    }

    // Pick best reachable final state.
    var best_final: StateId = no_state;
    var best_total = W.zero;
    for (0..num_states) |i| {
        const s: StateId = @intCast(i);
        if (dist[s].isZero()) continue;
        const fw = fst.finalWeight(s);
        if (fw.isZero()) continue;
        const total = W.times(dist[s], fw);
        if (best_final == no_state or
            W.compare(total, best_total) == .lt or
            (W.compare(total, best_total) == .eq and s < best_final))
        {
            best_final = s;
            best_total = total;
        }
    }
    if (best_final == no_state) {
        return mutable_fst_mod.MutableFst(W).init(allocator);
    }

    // Build result: trace back the best path.
    var result = mutable_fst_mod.MutableFst(W).init(allocator);
    errdefer result.deinit();
    var reverse_edges: std.ArrayList(BackPtr) = .empty;
    var current = best_final;
    while (back[current]) |bp| {
        try reverse_edges.append(arena, bp);
        current = bp.prev_state;
    }

    // If best_final is reachable, backtrace must end at the start state.
    if (current != fst.start()) {
        return mutable_fst_mod.MutableFst(W).init(allocator);
    }

    try result.addStates(reverse_edges.items.len + 1);
    result.setStart(0);
    result.setFinal(@intCast(reverse_edges.items.len), fst.finalWeight(best_final));

    var out_idx: usize = 0;
    var i = reverse_edges.items.len;
    while (i > 0) {
        i -= 1;
        const bp = reverse_edges.items[i];
        const arc = fst.arcs(bp.prev_state)[bp.arc_idx];
        try result.addArc(@intCast(out_idx), A.init(arc.ilabel, arc.olabel, arc.weight, @intCast(out_idx + 1)));
        out_idx += 1;
    }

    return result;
}

// ── Tests ──

test "shortest-path: single best path" {
    const W = @import("../weight.zig").TropicalWeight;
    const A = arc_mod.Arc(W);
    const allocator = std.testing.allocator;

    // 0 --a/1.0--> 1 --b/2.0--> 2(final, 0)
    // 0 --c/5.0--> 3 --d/1.0--> 2(final, 0)
    // Best path: 0->1->2 with total weight 3.0
    var fst = mutable_fst_mod.MutableFst(W).init(allocator);
    defer fst.deinit();

    _ = try fst.addState(); // 0
    _ = try fst.addState(); // 1
    _ = try fst.addState(); // 2
    _ = try fst.addState(); // 3
    fst.setStart(0);
    fst.setFinal(2, W.one);
    try fst.addArc(0, A.init(1, 1, W.init(1.0), 1));
    try fst.addArc(1, A.init(2, 2, W.init(2.0), 2));
    try fst.addArc(0, A.init(3, 3, W.init(5.0), 3));
    try fst.addArc(3, A.init(4, 4, W.init(1.0), 2));

    var result = try shortestPath(W, allocator, &fst, 1);
    defer result.deinit();

    try std.testing.expect(result.start() != no_state);

    // Should be a linear chain of 3 states
    try std.testing.expectEqual(3, result.numStates());

    // First arc should have weight 1.0
    const first_arc = result.arcs(result.start())[0];
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), first_arc.weight.value, 0.001);
}

test "shortest-path: empty FST" {
    const W = @import("../weight.zig").TropicalWeight;
    const allocator = std.testing.allocator;

    var fst = mutable_fst_mod.MutableFst(W).init(allocator);
    defer fst.deinit();

    var result = try shortestPath(W, allocator, &fst, 1);
    defer result.deinit();

    try std.testing.expectEqual(no_state, result.start());
}

test "shortest-path: preserves selected arc when multiple arcs share nextstate" {
    const W = @import("../weight.zig").TropicalWeight;
    const A = arc_mod.Arc(W);
    const allocator = std.testing.allocator;

    var fst = mutable_fst_mod.MutableFst(W).init(allocator);
    defer fst.deinit();
    _ = try fst.addState(); // 0
    _ = try fst.addState(); // 1
    fst.setStart(0);
    fst.setFinal(1, W.one);

    // Both arcs go to state 1; shortest path must choose the cheaper one.
    try fst.addArc(0, A.init(10, 100, W.init(3.0), 1));
    try fst.addArc(0, A.init(11, 101, W.init(1.0), 1));

    var result = try shortestPath(W, allocator, &fst, 1);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.numStates());
    const arcs = result.arcs(0);
    try std.testing.expectEqual(@as(usize, 1), arcs.len);
    try std.testing.expectEqual(@as(u32, 11), arcs[0].ilabel);
    try std.testing.expectEqual(@as(u32, 101), arcs[0].olabel);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), arcs[0].weight.value, 0.001);
}

test "shortest-path: n > 1 not supported" {
    const W = @import("../weight.zig").TropicalWeight;
    const allocator = std.testing.allocator;

    var fst = mutable_fst_mod.MutableFst(W).init(allocator);
    defer fst.deinit();
    _ = try fst.addState();
    fst.setStart(0);
    fst.setFinal(0, W.one);

    try std.testing.expectError(error.UnsupportedNShortest, shortestPath(W, allocator, &fst, 2));
}
