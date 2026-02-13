const std = @import("std");
const arc_mod = @import("../arc.zig");
const mutable_fst_mod = @import("../mutable-fst.zig");

const StateId = arc_mod.StateId;

pub const ProjectType = enum {
    input, // project to input tape (olabel = ilabel)
    output, // project to output tape (ilabel = olabel)
};

/// Project an FST to one of its tapes, making it an acceptor.
/// - input: sets olabel = ilabel for all arcs
/// - output: sets ilabel = olabel for all arcs
/// Modifies fst in-place. O(total arcs).
pub fn project(comptime W: type, fst: *mutable_fst_mod.MutableFst(W), side: ProjectType) void {
    for (0..fst.numStates()) |i| {
        const s: StateId = @intCast(i);
        for (fst.arcsMut(s)) |*a| {
            switch (side) {
                .input => a.olabel = a.ilabel,
                .output => a.ilabel = a.olabel,
            }
        }
    }
}

// ── Tests ──

test "project: input" {
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

    project(W, &fst, .input);

    const a = fst.arcs(s0)[0];
    try std.testing.expectEqual(@as(arc_mod.Label, 1), a.ilabel);
    try std.testing.expectEqual(@as(arc_mod.Label, 1), a.olabel);
}

test "project: output" {
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

    project(W, &fst, .output);

    const a = fst.arcs(s0)[0];
    try std.testing.expectEqual(@as(arc_mod.Label, 2), a.ilabel);
    try std.testing.expectEqual(@as(arc_mod.Label, 2), a.olabel);
}
