const std = @import("std");
const arc_mod = @import("../arc.zig");
const mutable_fst_mod = @import("../mutable-fst.zig");

const Label = arc_mod.Label;
const StateId = arc_mod.StateId;
const epsilon = arc_mod.epsilon;
const no_state = arc_mod.no_state;
const Allocator = std.mem.Allocator;

/// Remove epsilon transitions from an FST.
/// For each state, compute the epsilon closure (set of states reachable via
/// epsilon arcs) and redirect non-epsilon arcs through the closure.
/// Returns a new MutableFst with no epsilon transitions.
pub fn rmEpsilon(comptime W: type, allocator: Allocator, fst: *const mutable_fst_mod.MutableFst(W)) !mutable_fst_mod.MutableFst(W) {
    const A = arc_mod.Arc(W);
    const num_states = fst.numStates();
    if (num_states == 0 or fst.start() == no_state) {
        return mutable_fst_mod.MutableFst(W).init(allocator);
    }

    // Arena for all temporaries — freed in bulk on return
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var result = mutable_fst_mod.MutableFst(W).init(allocator);
    errdefer result.deinit();

    // Create same number of states
    try result.addStates(num_states);
    result.setStart(fst.start());

    // Temp buffers for epsilon closure computation
    var closure_states: std.ArrayList(StateId) = .empty;
    var closure_weights: std.ArrayList(W) = .empty;

    var visited = try arena.alloc(bool, num_states);

    var stack_s: std.ArrayList(StateId) = .empty;
    var stack_w: std.ArrayList(W) = .empty;

    for (0..num_states) |i| {
        const s: StateId = @intCast(i);

        // Compute epsilon closure of state s
        closure_states.clearRetainingCapacity();
        closure_weights.clearRetainingCapacity();
        @memset(visited, false);
        stack_s.clearRetainingCapacity();
        stack_w.clearRetainingCapacity();

        try stack_s.append(arena, s);
        try stack_w.append(arena, W.one);
        visited[s] = true;

        while (stack_s.items.len > 0) {
            const current = stack_s.pop().?;
            const current_w = stack_w.pop().?;
            try closure_states.append(arena, current);
            try closure_weights.append(arena, current_w);

            for (fst.arcs(current)) |a| {
                if (a.ilabel == epsilon and a.olabel == epsilon) {
                    if (!visited[a.nextstate]) {
                        visited[a.nextstate] = true;
                        try stack_s.append(arena, a.nextstate);
                        try stack_w.append(arena, W.times(current_w, a.weight));
                    }
                }
            }
        }

        // Set final weight: combine with epsilon-reachable final states
        var final_w = fst.finalWeight(s);
        for (closure_states.items, closure_weights.items) |ec_state, ec_weight| {
            if (ec_state == s) continue;
            const fw = fst.finalWeight(ec_state);
            if (!fw.isZero()) {
                final_w = W.plus(final_w, W.times(ec_weight, fw));
            }
        }
        if (!final_w.isZero()) {
            result.setFinal(s, final_w);
        }

        // Add non-epsilon arcs from closure
        for (closure_states.items, closure_weights.items) |ec_state, ec_weight| {
            for (fst.arcs(ec_state)) |a| {
                if (a.ilabel != epsilon or a.olabel != epsilon) {
                    try result.addArc(s, A.init(
                        a.ilabel,
                        a.olabel,
                        W.times(ec_weight, a.weight),
                        a.nextstate,
                    ));
                }
            }
        }
    }

    return result;
}

// ── Tests ──

test "rm-epsilon: simple chain" {
    const W = @import("../weight.zig").TropicalWeight;
    const A = arc_mod.Arc(W);
    const allocator = std.testing.allocator;

    // 0 --eps/1.0--> 1 --a/2.0--> 2(final)
    var fst = mutable_fst_mod.MutableFst(W).init(allocator);
    defer fst.deinit();

    const s0 = try fst.addState();
    const s1 = try fst.addState();
    const s2 = try fst.addState();
    fst.setStart(s0);
    fst.setFinal(s2, W.one);
    try fst.addArc(s0, A.initEpsilon(W.init(1.0), s1));
    try fst.addArc(s1, A.init('a' + 1, 'a' + 1, W.init(2.0), s2));

    var result = try rmEpsilon(W, allocator, &fst);
    defer result.deinit();

    // State 0 should now have a direct arc to state 2
    // with weight = times(1.0, 2.0) = 3.0
    var found = false;
    for (result.arcs(s0)) |a| {
        if (a.ilabel == 'a' + 1 and a.nextstate == s2) {
            try std.testing.expectApproxEqAbs(@as(f64, 3.0), a.weight.value, 0.001);
            found = true;
        }
    }
    try std.testing.expect(found);
}

test "rm-epsilon: final weight through epsilon" {
    const W = @import("../weight.zig").TropicalWeight;
    const A = arc_mod.Arc(W);
    const allocator = std.testing.allocator;

    // 0 --eps/1.0--> 1(final, weight=2.0)
    var fst = mutable_fst_mod.MutableFst(W).init(allocator);
    defer fst.deinit();

    const s0 = try fst.addState();
    const s1 = try fst.addState();
    fst.setStart(s0);
    fst.setFinal(s1, W.init(2.0));
    try fst.addArc(s0, A.initEpsilon(W.init(1.0), s1));

    var result = try rmEpsilon(W, allocator, &fst);
    defer result.deinit();

    // State 0 should now be final with weight = times(1.0, 2.0) = 3.0
    try std.testing.expect(result.isFinal(0));
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.finalWeight(0).value, 0.001);
}

test "rm-epsilon: no epsilons" {
    const W = @import("../weight.zig").TropicalWeight;
    const string = @import("../string.zig");
    const allocator = std.testing.allocator;

    var fst = try string.compileString(W, allocator, "abc");
    defer fst.deinit();

    var result = try rmEpsilon(W, allocator, &fst);
    defer result.deinit();

    // Should be identical structure
    try std.testing.expectEqual(fst.numStates(), result.numStates());
    try std.testing.expectEqual(fst.totalArcs(), result.totalArcs());
}
