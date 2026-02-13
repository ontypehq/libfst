const std = @import("std");
const arc_mod = @import("../arc.zig");
const mutable_fst_mod = @import("../mutable-fst.zig");

const Label = arc_mod.Label;
const StateId = arc_mod.StateId;
const epsilon = arc_mod.epsilon;
const no_state = arc_mod.no_state;

/// Compute the union of two FSTs: L(fst1) ∪ L(fst2).
/// Modifies fst1 in-place by adding a new start state with epsilon arcs
/// to both original start states.
///
/// Note: On error (OOM), fst1 is left in an inconsistent state and should
/// not be used further. Callers who need rollback should clone before calling.
pub fn union_(comptime W: type, fst1: *mutable_fst_mod.MutableFst(W), fst2: *const mutable_fst_mod.MutableFst(W)) !void {
    const A = arc_mod.Arc(W);

    if (fst2.start() == no_state) return;

    const old_start1 = fst1.start();
    const offset: StateId = @intCast(fst1.numStates());

    // Copy all states from fst2 into fst1
    try fst1.addStates(fst2.numStates());
    for (0..fst2.numStates()) |i| {
        const src: StateId = @intCast(i);
        const dst: StateId = src + offset;

        // Copy final weight
        const fw = fst2.finalWeight(src);
        if (!fw.isZero()) {
            fst1.setFinal(dst, fw);
        }

        // Copy arcs with remapped state IDs
        for (fst2.arcs(src)) |a| {
            try fst1.addArc(dst, A.init(a.ilabel, a.olabel, a.weight, a.nextstate + offset));
        }
    }

    // Add new super-start state
    const new_start = try fst1.addState();
    if (old_start1 != no_state) {
        try fst1.addArc(new_start, A.initEpsilon(W.one, old_start1));
    }
    try fst1.addArc(new_start, A.initEpsilon(W.one, fst2.start() + offset));
    fst1.setStart(new_start);
}

// ── Tests ──

test "union: simple" {
    const W = @import("../weight.zig").TropicalWeight;
    const A = arc_mod.Arc(W);
    const string = @import("../string.zig");
    const allocator = std.testing.allocator;

    // FST1 accepts "a" (label 'a'+1)
    var fst1 = try string.compileString(W, allocator, "a");
    defer fst1.deinit();

    // FST2 accepts "b"
    var fst2 = try string.compileString(W, allocator, "b");
    defer fst2.deinit();

    try union_(W, &fst1, &fst2);

    // New start state should have two epsilon arcs
    const start_s = fst1.start();
    try std.testing.expect(start_s != no_state);
    const start_arcs = fst1.arcs(start_s);
    try std.testing.expectEqual(@as(usize, 2), start_arcs.len);
    try std.testing.expect(start_arcs[0].isEpsilon());
    try std.testing.expect(start_arcs[1].isEpsilon());
    _ = A;
}

test "union: empty fst2" {
    const W = @import("../weight.zig").TropicalWeight;
    const string = @import("../string.zig");
    const allocator = std.testing.allocator;

    var fst1 = try string.compileString(W, allocator, "a");
    defer fst1.deinit();

    var fst2 = mutable_fst_mod.MutableFst(W).init(allocator);
    defer fst2.deinit();

    const old_num = fst1.numStates();
    try union_(W, &fst1, &fst2);
    // Should not change fst1
    try std.testing.expectEqual(old_num, fst1.numStates());
}
