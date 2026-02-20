const std = @import("std");
const arc_mod = @import("../arc.zig");
const mutable_fst_mod = @import("../mutable-fst.zig");

const Label = arc_mod.Label;
const StateId = arc_mod.StateId;
const epsilon = arc_mod.epsilon;
const no_state = arc_mod.no_state;
const Allocator = std.mem.Allocator;

fn toWeight(comptime W: type, value: anytype) W {
    const T = @TypeOf(value);
    if (T == W) return value;
    if (T == f64) return W.init(value);
    if (T == f32) return W.init(@as(f64, value));
    if (T == f16) return W.init(@as(f64, value));
    @compileError("composeShortestPath: unsupported arc weight type");
}

/// Compute shortest path on the implicit composition graph without building the
/// full composed lattice. This is equivalent to:
///   shortest_path(compose(fst1, fst2), n=1)
///
/// `n` is accepted for C-surface compatibility, but only `n == 1` is
/// supported. `n == 0` returns an empty FST.
pub fn composeShortestPath(comptime W: type, allocator: Allocator, fst1: anytype, fst2: anytype, n: u32) !mutable_fst_mod.MutableFst(W) {
    const A = arc_mod.Arc(W);
    const rhs_has_label_lookup = comptime @hasDecl(@TypeOf(fst2.*), "arcsByIlabel");

    if (fst1.start() == no_state or fst2.start() == no_state or n == 0) {
        return mutable_fst_mod.MutableFst(W).init(allocator);
    }
    if (n != 1) return error.UnsupportedNShortest;

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const StateTuple = struct {
        s1: StateId,
        s2: StateId,
        filter: u8,
    };
    const BackPtr = struct {
        prev_id: u32,
        ilabel: Label,
        olabel: Label,
        weight: W,
    };
    const QueueItem = struct {
        tuple_id: u32,
        dist: W,
    };

    const queueCompare = struct {
        fn call(_: void, a: QueueItem, b: QueueItem) std.math.Order {
            const by_dist = W.compare(a.dist, b.dist);
            if (by_dist != .eq) return by_dist;
            return std.math.order(a.tuple_id, b.tuple_id);
        }
    }.call;

    var tuple_to_id: std.AutoHashMapUnmanaged(StateTuple, u32) = .empty;
    var tuples: std.ArrayList(StateTuple) = .empty;
    var dist: std.ArrayList(W) = .empty;
    var back: std.ArrayList(?BackPtr) = .empty;
    var settled: std.ArrayList(bool) = .empty;
    var queue = std.PriorityQueue(QueueItem, void, queueCompare).init(arena, {});

    const getOrCreate = struct {
        fn call(
            t2id: *std.AutoHashMapUnmanaged(StateTuple, u32),
            tlist: *std.ArrayList(StateTuple),
            dlist: *std.ArrayList(W),
            blist: *std.ArrayList(?BackPtr),
            slist: *std.ArrayList(bool),
            a: Allocator,
            tuple: StateTuple,
        ) !u32 {
            if (t2id.get(tuple)) |id| return id;
            const id: u32 = @intCast(tlist.items.len);
            try tlist.append(a, tuple);
            try dlist.append(a, W.zero);
            try blist.append(a, null);
            try slist.append(a, false);
            try t2id.put(a, tuple, id);
            return id;
        }
    }.call;

    const relax = struct {
        fn call(
            comptime Weight: type,
            t2id: *std.AutoHashMapUnmanaged(StateTuple, u32),
            tlist: *std.ArrayList(StateTuple),
            dlist: *std.ArrayList(Weight),
            blist: *std.ArrayList(?BackPtr),
            slist: *std.ArrayList(bool),
            pq: *std.PriorityQueue(QueueItem, void, queueCompare),
            a: Allocator,
            curr_id: u32,
            next_tuple: StateTuple,
            ilabel: Label,
            olabel: Label,
            edge_weight: Weight,
        ) !void {
            const next_id = try getOrCreate(t2id, tlist, dlist, blist, slist, a, next_tuple);
            const new_dist = Weight.times(dlist.items[curr_id], edge_weight);
            const old_dist = dlist.items[next_id];
            const by_dist = Weight.compare(new_dist, old_dist);

            var take = false;
            if (old_dist.isZero() or by_dist == .lt) {
                take = true;
            } else if (by_dist == .eq) {
                if (blist.items[next_id]) |bp| {
                    if (curr_id < bp.prev_id or
                        (curr_id == bp.prev_id and (ilabel < bp.ilabel or
                            (ilabel == bp.ilabel and olabel < bp.olabel))))
                    {
                        take = true;
                    }
                } else {
                    take = true;
                }
            }

            if (!take) return;

            dlist.items[next_id] = new_dist;
            blist.items[next_id] = .{
                .prev_id = curr_id,
                .ilabel = ilabel,
                .olabel = olabel,
                .weight = edge_weight,
            };
            if (!slist.items[next_id]) {
                try pq.add(.{
                    .tuple_id = next_id,
                    .dist = new_dist,
                });
            }
        }
    }.call;

    const init_tuple = StateTuple{
        .s1 = fst1.start(),
        .s2 = fst2.start(),
        .filter = 0,
    };
    const init_id = try getOrCreate(&tuple_to_id, &tuples, &dist, &back, &settled, arena, init_tuple);
    dist.items[init_id] = W.one;
    try queue.add(.{ .tuple_id = init_id, .dist = W.one });

    var best_final_id: ?u32 = null;
    var best_final_weight = W.zero;
    var best_total = W.zero;

    while (queue.removeOrNull()) |item| {
        const curr_id = item.tuple_id;
        if (settled.items[curr_id]) continue;
        if (W.compare(item.dist, dist.items[curr_id]) != .eq) continue; // stale entry
        settled.items[curr_id] = true;

        const t = tuples.items[curr_id];
        const fw1 = fst1.finalWeight(t.s1);
        const fw2 = fst2.finalWeight(t.s2);
        if (!fw1.isZero() and !fw2.isZero()) {
            const final_w = W.times(fw1, fw2);
            const total = W.times(dist.items[curr_id], final_w);
            if (best_final_id == null or
                W.compare(total, best_total) == .lt or
                (W.compare(total, best_total) == .eq and curr_id < best_final_id.?))
            {
                best_final_id = curr_id;
                best_final_weight = final_w;
                best_total = total;
            }
        }

        // Non-epsilon matches.
        for (fst1.arcs(t.s1)) |a1| {
            if (a1.olabel == epsilon) continue;
            if (comptime rhs_has_label_lookup) {
                for (fst2.arcsByIlabel(t.s2, a1.olabel)) |a2| {
                    const next = StateTuple{ .s1 = a1.nextstate, .s2 = a2.nextstate, .filter = 0 };
                    try relax(
                        W,
                        &tuple_to_id,
                        &tuples,
                        &dist,
                        &back,
                        &settled,
                        &queue,
                        arena,
                        curr_id,
                        next,
                        a1.ilabel,
                        a2.olabel,
                        W.times(toWeight(W, a1.weight), toWeight(W, a2.weight)),
                    );
                }
            } else {
                for (fst2.arcs(t.s2)) |a2| {
                    if (a2.ilabel != a1.olabel) continue;
                    const next = StateTuple{ .s1 = a1.nextstate, .s2 = a2.nextstate, .filter = 0 };
                    try relax(
                        W,
                        &tuple_to_id,
                        &tuples,
                        &dist,
                        &back,
                        &settled,
                        &queue,
                        arena,
                        curr_id,
                        next,
                        a1.ilabel,
                        a2.olabel,
                        W.times(toWeight(W, a1.weight), toWeight(W, a2.weight)),
                    );
                }
            }
        }

        // Epsilon sequencing filter (same semantics as compose()).
        if (t.filter != 1) {
            for (fst1.arcs(t.s1)) |a1| {
                if (a1.olabel != epsilon) continue;
                const new_filter: u8 = if (t.filter == 0) 2 else t.filter;
                const next = StateTuple{
                    .s1 = a1.nextstate,
                    .s2 = t.s2,
                    .filter = new_filter,
                };
                try relax(
                    W,
                    &tuple_to_id,
                    &tuples,
                    &dist,
                    &back,
                    &settled,
                    &queue,
                    arena,
                    curr_id,
                    next,
                    a1.ilabel,
                    epsilon,
                    toWeight(W, a1.weight),
                );
            }
        }

        if (t.filter != 2) {
            if (comptime rhs_has_label_lookup) {
                for (fst2.arcsByIlabel(t.s2, epsilon)) |a2| {
                    const new_filter: u8 = if (t.filter == 0) 1 else t.filter;
                    const next = StateTuple{
                        .s1 = t.s1,
                        .s2 = a2.nextstate,
                        .filter = new_filter,
                    };
                    try relax(
                        W,
                        &tuple_to_id,
                        &tuples,
                        &dist,
                        &back,
                        &settled,
                        &queue,
                        arena,
                        curr_id,
                        next,
                        epsilon,
                        a2.olabel,
                        toWeight(W, a2.weight),
                    );
                }
            } else {
                for (fst2.arcs(t.s2)) |a2| {
                    if (a2.ilabel != epsilon) continue;
                    const new_filter: u8 = if (t.filter == 0) 1 else t.filter;
                    const next = StateTuple{
                        .s1 = t.s1,
                        .s2 = a2.nextstate,
                        .filter = new_filter,
                    };
                    try relax(
                        W,
                        &tuple_to_id,
                        &tuples,
                        &dist,
                        &back,
                        &settled,
                        &queue,
                        arena,
                        curr_id,
                        next,
                        epsilon,
                        a2.olabel,
                        toWeight(W, a2.weight),
                    );
                }
            }
        }

        if (t.filter == 0) {
            if (comptime rhs_has_label_lookup) {
                const rhs_eps = fst2.arcsByIlabel(t.s2, epsilon);
                if (rhs_eps.len > 0) {
                    for (fst1.arcs(t.s1)) |a1| {
                        if (a1.olabel != epsilon) continue;
                        for (rhs_eps) |a2| {
                            const next = StateTuple{
                                .s1 = a1.nextstate,
                                .s2 = a2.nextstate,
                                .filter = 0,
                            };
                            try relax(
                                W,
                                &tuple_to_id,
                                &tuples,
                                &dist,
                                &back,
                                &settled,
                                &queue,
                                arena,
                                curr_id,
                                next,
                                a1.ilabel,
                                a2.olabel,
                                W.times(toWeight(W, a1.weight), toWeight(W, a2.weight)),
                            );
                        }
                    }
                }
            } else {
                for (fst1.arcs(t.s1)) |a1| {
                    if (a1.olabel != epsilon) continue;
                    for (fst2.arcs(t.s2)) |a2| {
                        if (a2.ilabel != epsilon) continue;
                        const next = StateTuple{
                            .s1 = a1.nextstate,
                            .s2 = a2.nextstate,
                            .filter = 0,
                        };
                        try relax(
                            W,
                            &tuple_to_id,
                            &tuples,
                            &dist,
                            &back,
                            &settled,
                            &queue,
                            arena,
                            curr_id,
                            next,
                            a1.ilabel,
                            a2.olabel,
                            W.times(toWeight(W, a1.weight), toWeight(W, a2.weight)),
                        );
                    }
                }
            }
        }
    }

    if (best_final_id == null) {
        return mutable_fst_mod.MutableFst(W).init(allocator);
    }

    var reverse: std.ArrayList(BackPtr) = .empty;
    var curr = best_final_id.?;
    while (curr != init_id) {
        const bp = back.items[curr] orelse {
            return mutable_fst_mod.MutableFst(W).init(allocator);
        };
        try reverse.append(arena, bp);
        curr = bp.prev_id;
    }

    var result = mutable_fst_mod.MutableFst(W).init(allocator);
    errdefer result.deinit();
    try result.addStates(reverse.items.len + 1);
    result.setStart(0);
    result.setFinal(@intCast(reverse.items.len), best_final_weight);

    var out_idx: usize = 0;
    var i = reverse.items.len;
    while (i > 0) {
        i -= 1;
        const bp = reverse.items[i];
        try result.addArc(
            @intCast(out_idx),
            A.init(bp.ilabel, bp.olabel, bp.weight, @intCast(out_idx + 1)),
        );
        out_idx += 1;
    }

    return result;
}

fn expectFstEq(comptime W: type, lhs: *mutable_fst_mod.MutableFst(W), rhs: *mutable_fst_mod.MutableFst(W)) !void {
    lhs.sortAllArcs();
    rhs.sortAllArcs();

    try std.testing.expectEqual(lhs.start(), rhs.start());
    try std.testing.expectEqual(lhs.numStates(), rhs.numStates());
    for (0..lhs.numStates()) |i| {
        const s: StateId = @intCast(i);
        try std.testing.expectEqual(lhs.numArcs(s), rhs.numArcs(s));
        try std.testing.expect(lhs.finalWeight(s).eql(rhs.finalWeight(s)));
        const a_arcs = lhs.arcs(s);
        const b_arcs = rhs.arcs(s);
        for (a_arcs, b_arcs) |aa, bb| {
            try std.testing.expectEqual(aa.ilabel, bb.ilabel);
            try std.testing.expectEqual(aa.olabel, bb.olabel);
            try std.testing.expect(aa.weight.eql(bb.weight));
            try std.testing.expectEqual(aa.nextstate, bb.nextstate);
        }
    }
}

test "compose-shortest-path: equals compose+shortest-path with mutable rhs" {
    const W = @import("../weight.zig").TropicalWeight;
    const compose_mod = @import("compose.zig");
    const shortest_path_mod = @import("shortest-path.zig");
    const string = @import("../string.zig");
    const allocator = std.testing.allocator;

    var lhs = try string.compileString(W, allocator, "123");
    defer lhs.deinit();
    var rhs = try string.compileStringTransducer(W, allocator, "123", "abc");
    defer rhs.deinit();

    var lazy = try composeShortestPath(W, allocator, &lhs, &rhs, 1);
    defer lazy.deinit();

    var composed = try compose_mod.compose(W, allocator, &lhs, &rhs);
    defer composed.deinit();
    var eager = try shortest_path_mod.shortestPath(W, allocator, &composed, 1);
    defer eager.deinit();

    try expectFstEq(W, &lazy, &eager);
}

test "compose-shortest-path: equals compose+shortest-path with frozen rhs" {
    const W = @import("../weight.zig").TropicalWeight;
    const compose_mod = @import("compose.zig");
    const shortest_path_mod = @import("shortest-path.zig");
    const string = @import("../string.zig");
    const fst_mod = @import("../fst.zig");
    const allocator = std.testing.allocator;

    var lhs = try string.compileString(W, allocator, "123");
    defer lhs.deinit();
    var rhs_mut = try string.compileStringTransducer(W, allocator, "123", "abc");
    defer rhs_mut.deinit();
    var rhs_frozen = try fst_mod.Fst(W).fromMutable(allocator, &rhs_mut);
    defer rhs_frozen.deinit();

    var lazy = try composeShortestPath(W, allocator, &lhs, &rhs_frozen, 1);
    defer lazy.deinit();

    var composed = try compose_mod.compose(W, allocator, &lhs, &rhs_frozen);
    defer composed.deinit();
    var eager = try shortest_path_mod.shortestPath(W, allocator, &composed, 1);
    defer eager.deinit();

    try expectFstEq(W, &lazy, &eager);
}
