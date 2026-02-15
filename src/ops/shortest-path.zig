const std = @import("std");
const arc_mod = @import("../arc.zig");
const mutable_fst_mod = @import("../mutable-fst.zig");

const Label = arc_mod.Label;
const StateId = arc_mod.StateId;
const epsilon = arc_mod.epsilon;
const no_state = arc_mod.no_state;
const Allocator = std.mem.Allocator;

/// Find the n-best (shortest) paths through a weighted FST.
/// Uses Dijkstra-like search with deterministic tie-breaking:
///   1. Compare weights (lower is better for tropical)
///   2. If equal, compare state IDs ascending
///
/// Returns a new MutableFst containing the n-best paths as a tree.
pub fn shortestPath(comptime W: type, allocator: Allocator, fst: *const mutable_fst_mod.MutableFst(W), n: u32) !mutable_fst_mod.MutableFst(W) {
    const A = arc_mod.Arc(W);

    if (fst.start() == no_state or n == 0) {
        return mutable_fst_mod.MutableFst(W).init(allocator);
    }

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

    // Find n-best final states
    const FinalCandidate = struct {
        state: StateId,
        total_weight: W,
    };
    var candidates: std.ArrayList(FinalCandidate) = .empty;

    for (0..num_states) |i| {
        const s: StateId = @intCast(i);
        if (dist[s].isZero()) continue;
        const fw = fst.finalWeight(s);
        if (fw.isZero()) continue;
        try candidates.append(arena, .{
            .state = s,
            .total_weight = W.times(dist[s], fw),
        });
    }

    // Sort by total weight (ascending for tropical)
    std.mem.sort(FinalCandidate, candidates.items, {}, struct {
        fn lessThan(_: void, a_: FinalCandidate, b_: FinalCandidate) bool {
            const cmp = W.compare(a_.total_weight, b_.total_weight);
            if (cmp == .lt) return true;
            if (cmp == .gt) return false;
            return a_.state < b_.state;
        }
    }.lessThan);

    // Take top n
    const take = @min(n, @as(u32, @intCast(candidates.items.len)));
    if (take == 0) {
        return mutable_fst_mod.MutableFst(W).init(allocator);
    }

    // Build result: for n=1, trace back the single best path
    var result = mutable_fst_mod.MutableFst(W).init(allocator);
    errdefer result.deinit();

    if (take == 1) {
        // Trace back single best path
        const best_final = candidates.items[0].state;
        var path: std.ArrayList(StateId) = .empty;

        var current = best_final;
        try path.append(arena, current);
        while (back[current]) |bp| {
            try path.append(arena, bp.prev_state);
            current = bp.prev_state;
        }

        // Reverse path
        std.mem.reverse(StateId, path.items);

        // Build linear FST
        try result.addStates(path.items.len);
        result.setStart(0);
        result.setFinal(@intCast(path.items.len - 1), fst.finalWeight(best_final));

        for (0..path.items.len - 1) |i| {
            const src = path.items[i];
            const dst = path.items[i + 1];
            // Find the arc from src to dst in original FST
            for (fst.arcs(src)) |a| {
                if (a.nextstate == dst) {
                    try result.addArc(@intCast(i), A.init(a.ilabel, a.olabel, a.weight, @intCast(i + 1)));
                    break;
                }
            }
        }
    } else {
        // For n > 1, build a tree with multiple paths
        // Each path shares common prefixes
        var state_map: std.AutoHashMapUnmanaged(StateId, StateId) = .empty;

        for (0..take) |ci| {
            const best_final = candidates.items[ci].state;
            var path: std.ArrayList(StateId) = .empty;

            var current = best_final;
            try path.append(arena, current);
            while (back[current]) |bp| {
                try path.append(arena, bp.prev_state);
                current = bp.prev_state;
            }
            std.mem.reverse(StateId, path.items);

            // Add path to result, reusing states where possible
            var prev_result_state: StateId = no_state;
            for (path.items, 0..) |orig_s, pi| {
                const rs = if (state_map.get(orig_s)) |existing|
                    existing
                else blk: {
                    const ns = try result.addState();
                    try state_map.put(arena, orig_s, ns);
                    break :blk ns;
                };

                if (pi == 0) {
                    result.setStart(rs);
                }
                if (pi == path.items.len - 1) {
                    result.setFinal(rs, fst.finalWeight(orig_s));
                }
                if (prev_result_state != no_state and pi > 0) {
                    const orig_prev = path.items[pi - 1];
                    // Find arc from prev to current
                    for (fst.arcs(orig_prev)) |a| {
                        if (a.nextstate == orig_s) {
                            // Check if this arc already exists
                            var exists = false;
                            for (result.arcs(prev_result_state)) |ra| {
                                if (ra.nextstate == rs and ra.ilabel == a.ilabel) {
                                    exists = true;
                                    break;
                                }
                            }
                            if (!exists) {
                                try result.addArc(prev_result_state, A.init(a.ilabel, a.olabel, a.weight, rs));
                            }
                            break;
                        }
                    }
                }
                prev_result_state = rs;
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
