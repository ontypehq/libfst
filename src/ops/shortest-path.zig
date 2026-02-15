const std = @import("std");
const arc_mod = @import("../arc.zig");
const mutable_fst_mod = @import("../mutable-fst.zig");

const Label = arc_mod.Label;
const StateId = arc_mod.StateId;
const epsilon = arc_mod.epsilon;
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

    // Dijkstra's algorithm to find shortest distances
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

    // Visited set
    var visited = try arena.alloc(bool, num_states);
    @memset(visited, false);

    // Simple priority queue (process states in order of distance)
    // For tropical semiring, lower weight = better = higher priority
    for (0..num_states) |_| {
        // Find unvisited state with best (minimum) distance
        var best: StateId = no_state;
        var best_dist = W.zero;
        for (0..num_states) |i| {
            const s: StateId = @intCast(i);
            if (visited[s]) continue;
            if (dist[s].isZero()) continue;
            if (best == no_state or
                W.compare(dist[s], best_dist) == .lt or
                (W.compare(dist[s], best_dist) == .eq and s < best))
            {
                best = s;
                best_dist = dist[s];
            }
        }

        if (best == no_state) break;
        visited[best] = true;

        // Relax edges
        for (fst.arcs(best), 0..) |a, ai| {
            const new_dist = W.times(dist[best], a.weight);
            if (dist[a.nextstate].isZero() or
                W.compare(new_dist, dist[a.nextstate]) == .lt or
                (W.compare(new_dist, dist[a.nextstate]) == .eq and best < (if (back[a.nextstate]) |bp| bp.prev_state else no_state)))
            {
                dist[a.nextstate] = new_dist;
                back[a.nextstate] = .{ .prev_state = best, .arc_idx = @intCast(ai) };
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
    var path: std.ArrayList(StateId) = .empty;

    var current = best_final;
    try path.append(arena, current);
    while (back[current]) |bp| {
        try path.append(arena, bp.prev_state);
        current = bp.prev_state;
    }

    std.mem.reverse(StateId, path.items);

    try result.addStates(path.items.len);
    result.setStart(0);
    result.setFinal(@intCast(path.items.len - 1), fst.finalWeight(best_final));

    for (0..path.items.len - 1) |i| {
        const src = path.items[i];
        const dst = path.items[i + 1];
        for (fst.arcs(src)) |a| {
            if (a.nextstate == dst) {
                try result.addArc(@intCast(i), A.init(a.ilabel, a.olabel, a.weight, @intCast(i + 1)));
                break;
            }
        }
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
