const std = @import("std");
const arc_mod = @import("../arc.zig");
const mutable_fst_mod = @import("../mutable-fst.zig");

const StateId = arc_mod.StateId;

/// Invert an FST by swapping input and output labels on all arcs.
/// Modifies fst in-place. O(total arcs).
pub fn invert(comptime W: type, fst: *mutable_fst_mod.MutableFst(W)) void {
    for (0..fst.numStates()) |i| {
        const s: StateId = @intCast(i);
        for (fst.arcsMut(s)) |*a| {
            const tmp = a.ilabel;
            a.ilabel = a.olabel;
            a.olabel = tmp;
        }
    }
}

// ── Tests ──

test "invert: swap labels" {
    const W = @import("../weight.zig").TropicalWeight;
    const A = arc_mod.Arc(W);
    const allocator = std.testing.allocator;

    var fst = mutable_fst_mod.MutableFst(W).init(allocator);
    defer fst.deinit();

    const s0 = try fst.addState();
    const s1 = try fst.addState();
    fst.setStart(s0);
    fst.setFinal(s1, W.one);
    try fst.addArc(s0, A.init(1, 2, W.one, s1));

    invert(W, &fst);

    const a = fst.arcs(s0)[0];
    try std.testing.expectEqual(@as(arc_mod.Label, 2), a.ilabel);
    try std.testing.expectEqual(@as(arc_mod.Label, 1), a.olabel);
}

test "invert: double invert is identity" {
    const W = @import("../weight.zig").TropicalWeight;
    const A = arc_mod.Arc(W);
    const allocator = std.testing.allocator;

    var fst = mutable_fst_mod.MutableFst(W).init(allocator);
    defer fst.deinit();

    const s0 = try fst.addState();
    const s1 = try fst.addState();
    fst.setStart(s0);
    fst.setFinal(s1, W.one);
    try fst.addArc(s0, A.init(5, 10, W.init(2.0), s1));

    invert(W, &fst);
    invert(W, &fst);

    const a = fst.arcs(s0)[0];
    try std.testing.expectEqual(@as(arc_mod.Label, 5), a.ilabel);
    try std.testing.expectEqual(@as(arc_mod.Label, 10), a.olabel);
}
