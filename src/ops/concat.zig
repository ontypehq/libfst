const std = @import("std");
const arc_mod = @import("../arc.zig");
const mutable_fst_mod = @import("../mutable-fst.zig");

const StateId = arc_mod.StateId;
const epsilon = arc_mod.epsilon;
const no_state = arc_mod.no_state;

/// Concatenate two FSTs: L(fst1) · L(fst2).
/// Modifies fst1 in-place by connecting all final states of fst1
/// to the start state of fst2 via epsilon arcs.
///
/// Note: On error (OOM), fst1 is left in an inconsistent state and should
/// not be used further. Callers who need rollback should clone before calling.
pub fn concat(comptime W: type, fst1: *mutable_fst_mod.MutableFst(W), fst2: *const mutable_fst_mod.MutableFst(W)) !void {
    const A = arc_mod.Arc(W);

    if (fst2.start() == no_state) return;
    if (fst1.start() == no_state) return;

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

    // Connect fst1 final states to fst2 start state
    const fst2_start = fst2.start() + offset;
    for (0..offset) |i| {
        const s: StateId = @intCast(i);
        const fw = fst1.finalWeight(s);
        if (!fw.isZero()) {
            // Add epsilon arc weighted by the final weight
            try fst1.addArc(s, A.initEpsilon(fw, fst2_start));
            // Remove final weight from this state
            fst1.setFinal(s, W.zero);
        }
    }
}

// ── Tests ──

test "concat: simple" {
    const W = @import("../weight.zig").TropicalWeight;
    const string = @import("../string.zig");
    const allocator = std.testing.allocator;

    // FST1 accepts "a"
    var fst1 = try string.compileString(W, allocator, "a");
    defer fst1.deinit();

    // FST2 accepts "b"
    var fst2 = try string.compileString(W, allocator, "b");
    defer fst2.deinit();

    const orig_states = fst1.numStates() + fst2.numStates();
    try concat(W, &fst1, &fst2);

    // Total states should be sum of both
    try std.testing.expectEqual(orig_states, fst1.numStates());

    // Old final state of fst1 should no longer be final
    try std.testing.expect(!fst1.isFinal(1));

    // Last state should be final (from fst2)
    const last: StateId = @intCast(fst1.numStates() - 1);
    try std.testing.expect(fst1.isFinal(last));
}
