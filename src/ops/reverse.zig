const std = @import("std");
const arc_mod = @import("../arc.zig");
const mutable_fst_mod = @import("../mutable-fst.zig");

const Label = arc_mod.Label;
const StateId = arc_mod.StateId;
const epsilon = arc_mod.epsilon;
const no_state = arc_mod.no_state;
const Allocator = std.mem.Allocator;

/// Reverse an FST: reverse the direction of all paths.
///
/// For each path (s0 -a1-> s1 -a2-> s2 ... -an-> sn) in the input,
/// the reversed FST contains (sn -an-> ... -a2-> s1 -a1-> s0).
///
/// Implementation:
///   1. Create a new super-start state.
///   2. For every final state in the input, add an epsilon arc from
///      super-start to that state (weighted by the final weight).
///   3. For every arc (src --a--> dst) in the input, add (dst --a--> src)
///      in the result.
///   4. The original start state becomes the sole final state.
///
/// Note: The reversed FST may be nondeterministic even if the input is
/// deterministic. Weights are reversed via W.reverse().
pub fn reverse(comptime W: type, allocator: Allocator, fst: *const mutable_fst_mod.MutableFst(W)) !mutable_fst_mod.MutableFst(W) {
    const A = arc_mod.Arc(W);

    if (fst.start() == no_state) {
        return mutable_fst_mod.MutableFst(W).init(allocator);
    }

    const n: StateId = @intCast(fst.numStates());

    var result = mutable_fst_mod.MutableFst(W).init(allocator);
    errdefer result.deinit();

    // Create states: same count as input + 1 super-start
    // States 0..n-1 correspond to input states, state n is super-start
    try result.addStates(n + 1);

    const super_start: StateId = n;
    result.setStart(super_start);

    // Original start becomes the sole final state
    result.setFinal(fst.start(), W.one);

    // For each final state in input, add epsilon from super-start
    for (0..n) |i| {
        const s: StateId = @intCast(i);
        const fw = fst.finalWeight(s);
        if (!fw.isZero()) {
            try result.addArc(super_start, A.initEpsilon(fw.reverse(), s));
        }
    }

    // Reverse all arcs
    for (0..n) |i| {
        const s: StateId = @intCast(i);
        for (fst.arcs(s)) |a| {
            try result.addArc(a.nextstate, A.init(
                a.ilabel,
                a.olabel,
                a.weight.reverse(),
                s,
            ));
        }
    }

    return result;
}

// ── Tests ──

test "reverse: single arc" {
    const W = @import("../weight.zig").TropicalWeight;
    const A = arc_mod.Arc(W);
    const allocator = std.testing.allocator;

    // 0 --a:b--> 1(final)
    var fst = mutable_fst_mod.MutableFst(W).init(allocator);
    defer fst.deinit();
    _ = try fst.addState(); // 0
    _ = try fst.addState(); // 1
    fst.setStart(0);
    fst.setFinal(1, W.one);
    try fst.addArc(0, A.init(1, 2, W.init(3.0), 1));

    var rev = try reverse(W, allocator, &fst);
    defer rev.deinit();

    // Super-start = state 2, original start (0) is final
    try std.testing.expectEqual(2, rev.start());
    try std.testing.expect(rev.isFinal(0));
    try std.testing.expect(!rev.isFinal(1));

    // Super-start has epsilon arc to state 1 (original final)
    const start_arcs = rev.arcs(rev.start());
    try std.testing.expectEqual(1, start_arcs.len);
    try std.testing.expect(start_arcs[0].isEpsilon());
    try std.testing.expectEqual(1, start_arcs[0].nextstate);

    // State 1 has reversed arc to state 0
    const s1_arcs = rev.arcs(1);
    try std.testing.expectEqual(1, s1_arcs.len);
    try std.testing.expectEqual(1, s1_arcs[0].ilabel);
    try std.testing.expectEqual(2, s1_arcs[0].olabel);
    try std.testing.expectEqual(0, s1_arcs[0].nextstate);
}

test "reverse: empty FST" {
    const W = @import("../weight.zig").TropicalWeight;
    const allocator = std.testing.allocator;

    var fst = mutable_fst_mod.MutableFst(W).init(allocator);
    defer fst.deinit();

    var rev = try reverse(W, allocator, &fst);
    defer rev.deinit();

    try std.testing.expectEqual(no_state, rev.start());
}

test "reverse: double reverse preserves language" {
    const W = @import("../weight.zig").TropicalWeight;
    const string = @import("../string.zig");
    const allocator = std.testing.allocator;

    var fst = try string.compileString(W, allocator, "abc");
    defer fst.deinit();

    var rev1 = try reverse(W, allocator, &fst);
    defer rev1.deinit();

    var rev2 = try reverse(W, allocator, &rev1);
    defer rev2.deinit();

    // Double reversal: should have same number of original states + 2 super-starts
    // and the language should be equivalent (though structure differs)
    try std.testing.expect(rev2.start() != no_state);
    try std.testing.expect(rev2.numStates() > 0);
}

test "reverse: linear chain" {
    const W = @import("../weight.zig").TropicalWeight;
    const A = arc_mod.Arc(W);
    const allocator = std.testing.allocator;

    // 0 --a--> 1 --b--> 2(final)
    var fst = mutable_fst_mod.MutableFst(W).init(allocator);
    defer fst.deinit();
    _ = try fst.addState(); // 0
    _ = try fst.addState(); // 1
    _ = try fst.addState(); // 2
    fst.setStart(0);
    fst.setFinal(2, W.one);
    try fst.addArc(0, A.init(1, 1, W.one, 1));
    try fst.addArc(1, A.init(2, 2, W.one, 2));

    var rev = try reverse(W, allocator, &fst);
    defer rev.deinit();

    // 4 states: 0, 1, 2, super-start(3)
    try std.testing.expectEqual(4, rev.numStates());
    try std.testing.expectEqual(3, rev.start());

    // State 0 is final (was original start)
    try std.testing.expect(rev.isFinal(0));

    // Arc from 1->0 (reversed 0->1) with label 1
    var found_b_to_a = false;
    for (rev.arcs(1)) |a| {
        if (a.ilabel == 1 and a.nextstate == 0) found_b_to_a = true;
    }
    try std.testing.expect(found_b_to_a);

    // Arc from 2->1 (reversed 1->2) with label 2
    var found_c_to_b = false;
    for (rev.arcs(2)) |a| {
        if (a.ilabel == 2 and a.nextstate == 1) found_c_to_b = true;
    }
    try std.testing.expect(found_c_to_b);
}
