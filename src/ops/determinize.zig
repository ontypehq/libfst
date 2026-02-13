const std = @import("std");
const arc_mod = @import("../arc.zig");
const mutable_fst_mod = @import("../mutable-fst.zig");

const Label = arc_mod.Label;
const StateId = arc_mod.StateId;
const epsilon = arc_mod.epsilon;
const no_state = arc_mod.no_state;
const Allocator = std.mem.Allocator;

/// Determinize a weighted FST using the weighted subset construction.
/// Input FST should have no epsilon transitions (run rmEpsilon first).
/// Each state in the output corresponds to a weighted subset of input states.
pub fn determinize(comptime W: type, allocator: Allocator, fst: *const mutable_fst_mod.MutableFst(W)) !mutable_fst_mod.MutableFst(W) {
    const A = arc_mod.Arc(W);

    if (fst.start() == no_state) {
        return mutable_fst_mod.MutableFst(W).init(allocator);
    }

    // Arena for all temporaries — freed in bulk on return
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var result = mutable_fst_mod.MutableFst(W).init(allocator);
    errdefer result.deinit();

    // Store subsets as arrays of (state, residual_weight) pairs.
    // Each subset is identified by its index in `subsets`.
    var subset_states = std.ArrayListUnmanaged(std.ArrayListUnmanaged(SubsetElem(W))){};

    // Map canonical subset key -> subset index (= result state ID)
    var subset_map = std.StringHashMapUnmanaged(StateId){};

    // Queue of subset indices to process
    var queue = std.ArrayListUnmanaged(StateId){};

    // Temp buffers
    var labels_buf = std.ArrayListUnmanaged(Label){};
    var next_buf = std.ArrayListUnmanaged(SubsetElem(W)){};

    // Initial subset: {(start, One)}
    var init_subset = std.ArrayListUnmanaged(SubsetElem(W)){};
    try init_subset.append(arena, .{ .state = fst.start(), .weight = W.one });
    const init_key = try subsetKey(W, arena, init_subset.items);
    try subset_states.append(arena, init_subset);
    const init_id = try result.addState();
    result.setStart(init_id);
    try subset_map.put(arena, init_key, init_id);
    try queue.append(arena, init_id);

    var qi: usize = 0;
    while (qi < queue.items.len) : (qi += 1) {
        const current_id = queue.items[qi];
        const current_items = subset_states.items[current_id].items;

        // Compute final weight
        var final_w = W.zero;
        for (current_items) |elem| {
            const fw = fst.finalWeight(elem.state);
            if (!fw.isZero()) {
                final_w = W.plus(final_w, W.times(elem.weight, fw));
            }
        }
        if (!final_w.isZero()) {
            result.setFinal(current_id, final_w);
        }

        // Collect unique non-epsilon labels
        labels_buf.clearRetainingCapacity();
        for (current_items) |elem| {
            for (fst.arcs(elem.state)) |a| {
                if (a.ilabel != epsilon) {
                    var found = false;
                    for (labels_buf.items) |l| {
                        if (l == a.ilabel) { found = true; break; }
                    }
                    if (!found) try labels_buf.append(arena, a.ilabel);
                }
            }
        }

        // For each label, compute the next subset
        for (labels_buf.items) |label| {
            next_buf.clearRetainingCapacity();

            for (current_items) |elem| {
                for (fst.arcs(elem.state)) |a| {
                    if (a.ilabel == label) {
                        const new_w = W.times(elem.weight, a.weight);
                        var merged = false;
                        for (next_buf.items) |*ns| {
                            if (ns.state == a.nextstate) {
                                ns.weight = W.plus(ns.weight, new_w);
                                merged = true;
                                break;
                            }
                        }
                        if (!merged) {
                            try next_buf.append(arena, .{ .state = a.nextstate, .weight = new_w });
                        }
                    }
                }
            }

            if (next_buf.items.len == 0) continue;

            // Factor out common weight (min for tropical)
            var common = next_buf.items[0].weight;
            for (next_buf.items[1..]) |elem| common = W.plus(common, elem.weight);
            for (next_buf.items) |*elem| elem.weight = W.init(elem.weight.value - common.value);

            // Sort for canonical form
            std.mem.sort(SubsetElem(W), next_buf.items, {}, SubsetElem(W).lessThan);

            const next_key = try subsetKey(W, arena, next_buf.items);

            const next_state = if (subset_map.get(next_key)) |existing| blk: {
                break :blk existing;
            } else blk: {
                // Store a copy of the subset
                var next_copy = std.ArrayListUnmanaged(SubsetElem(W)){};
                try next_copy.appendSlice(arena, next_buf.items);
                try subset_states.append(arena, next_copy);
                const ns = try result.addState();
                try subset_map.put(arena, next_key, ns);
                try queue.append(arena, ns);
                break :blk ns;
            };

            // Pick first olabel for this ilabel
            var olabel: Label = label;
            for (current_items) |elem| {
                for (fst.arcs(elem.state)) |a| {
                    if (a.ilabel == label) { olabel = a.olabel; break; }
                }
            }

            try result.addArc(current_id, A.init(label, olabel, common, next_state));
        }
    }

    return result;
}

fn SubsetElem(comptime W: type) type {
    return struct {
        state: StateId,
        weight: W,

        fn lessThan(_: void, a: @This(), b: @This()) bool {
            return a.state < b.state;
        }
    };
}

fn subsetKey(comptime W: type, allocator: Allocator, subset: []const SubsetElem(W)) ![]u8 {
    // Encode as: state_id (4 bytes LE) + weight bits (8 bytes LE) per element
    const elem_size = 4 + 8;
    const buf = try allocator.alloc(u8, subset.len * elem_size);
    for (subset, 0..) |elem, i| {
        const off = i * elem_size;
        std.mem.writeInt(u32, buf[off..][0..4], elem.state, .little);
        const wbits: u64 = @bitCast(elem.weight.value);
        std.mem.writeInt(u64, buf[off + 4 ..][0..8], wbits, .little);
    }
    return buf;
}

// ── Tests ──

test "determinize: already deterministic" {
    const W = @import("../weight.zig").TropicalWeight;
    const string = @import("../string.zig");
    const allocator = std.testing.allocator;

    var fst = try string.compileString(W, allocator, "abc");
    defer fst.deinit();

    var result = try determinize(W, allocator, &fst);
    defer result.deinit();

    // Linear chain is already deterministic, state count should match
    try std.testing.expectEqual(fst.numStates(), result.numStates());
    try std.testing.expectEqual(fst.totalArcs(), result.totalArcs());
}

test "determinize: simple nondeterministic" {
    const W = @import("../weight.zig").TropicalWeight;
    const A = arc_mod.Arc(W);
    const allocator = std.testing.allocator;

    // NFA: state 0 has two arcs with same label 'a' going to different states
    // 0 --a/1.0--> 1(final)
    // 0 --a/2.0--> 2(final)
    var fst = mutable_fst_mod.MutableFst(W).init(allocator);
    defer fst.deinit();

    const s0 = try fst.addState();
    const s1 = try fst.addState();
    const s2 = try fst.addState();
    fst.setStart(s0);
    fst.setFinal(s1, W.one);
    fst.setFinal(s2, W.one);
    try fst.addArc(s0, A.init('a' + 1, 'a' + 1, W.init(1.0), s1));
    try fst.addArc(s0, A.init('a' + 1, 'a' + 1, W.init(2.0), s2));

    var result = try determinize(W, allocator, &fst);
    defer result.deinit();

    // Result should be deterministic: at most one arc per label from each state
    const start_arcs = result.arcs(result.start());
    var label_count: usize = 0;
    for (start_arcs) |a| {
        if (a.ilabel == 'a' + 1) label_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), label_count);

    // The best weight to a final state should be min(1.0, 2.0) = 1.0
    const a = start_arcs[0];
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), a.weight.value, 0.001);
}

test "determinize: idempotent" {
    const W = @import("../weight.zig").TropicalWeight;
    const A = arc_mod.Arc(W);
    const allocator = std.testing.allocator;

    var fst = mutable_fst_mod.MutableFst(W).init(allocator);
    defer fst.deinit();

    const s0 = try fst.addState();
    const s1 = try fst.addState();
    const s2 = try fst.addState();
    fst.setStart(s0);
    fst.setFinal(s1, W.one);
    fst.setFinal(s2, W.one);
    try fst.addArc(s0, A.init(1, 1, W.init(1.0), s1));
    try fst.addArc(s0, A.init(1, 1, W.init(2.0), s2));

    var det1 = try determinize(W, allocator, &fst);
    defer det1.deinit();

    var det2 = try determinize(W, allocator, &det1);
    defer det2.deinit();

    try std.testing.expectEqual(det1.numStates(), det2.numStates());
    try std.testing.expectEqual(det1.totalArcs(), det2.totalArcs());
}
