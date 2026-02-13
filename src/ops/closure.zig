const std = @import("std");
const arc_mod = @import("../arc.zig");
const mutable_fst_mod = @import("../mutable-fst.zig");

const StateId = arc_mod.StateId;
const epsilon = arc_mod.epsilon;
const no_state = arc_mod.no_state;

pub const ClosureType = enum {
    star, // zero or more (Kleene star)
    plus, // one or more (Kleene plus)
    ques, // zero or one (optional)
};

/// Apply closure to an FST.
/// - star: L* = {ε} ∪ L ∪ LL ∪ LLL ∪ ...
/// - plus: L+ = L ∪ LL ∪ LLL ∪ ...
/// - ques: L? = {ε} ∪ L
/// Modifies fst in-place.
///
/// Note: On error (OOM), fst is left in an inconsistent state and should
/// not be used further. Callers who need rollback should clone before calling.
pub fn closure(comptime W: type, fst: *mutable_fst_mod.MutableFst(W), closure_type: ClosureType) !void {
    const A = arc_mod.Arc(W);

    const old_start = fst.start();
    if (old_start == no_state) return;

    switch (closure_type) {
        .star => {
            // Add new start state (also final)
            const new_start = try fst.addState();
            fst.setFinal(new_start, W.one);
            fst.setStart(new_start);
            try fst.addArc(new_start, A.initEpsilon(W.one, old_start));

            // Connect all final states back to old start
            for (0..new_start) |i| {
                const s: StateId = @intCast(i);
                if (fst.isFinal(s)) {
                    try fst.addArc(s, A.initEpsilon(fst.finalWeight(s), old_start));
                }
            }
        },
        .plus => {
            // Connect all final states back to old start (no new start state)
            const num: StateId = @intCast(fst.numStates());
            for (0..num) |i| {
                const s: StateId = @intCast(i);
                if (fst.isFinal(s)) {
                    try fst.addArc(s, A.initEpsilon(fst.finalWeight(s), old_start));
                }
            }
        },
        .ques => {
            // Add new start state (also final) with epsilon to old start
            const new_start = try fst.addState();
            fst.setFinal(new_start, W.one);
            fst.setStart(new_start);
            try fst.addArc(new_start, A.initEpsilon(W.one, old_start));
        },
    }
}

/// Repeat an FST exactly n times: L^n = L · L · ... · L (n times).
pub fn repeat(comptime W: type, allocator: std.mem.Allocator, fst: *const mutable_fst_mod.MutableFst(W), min: u32, max: u32) !mutable_fst_mod.MutableFst(W) {
    const concat_mod = @import("concat.zig");

    if (min > max) return error.InvalidRange;

    if (min == 0 and max == 0) {
        // Empty language: single final state
        var result = mutable_fst_mod.MutableFst(W).init(allocator);
        const s = try result.addState();
        result.setStart(s);
        result.setFinal(s, W.one);
        return result;
    }

    // Arena for intermediate clones (optional copies) — freed in bulk on return
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Build L^min
    var result = try fst.clone(allocator);
    errdefer result.deinit();

    for (1..min) |_| {
        try concat_mod.concat(W, &result, fst);
    }

    if (max == min) return result;

    // For positions min..max, add optional copies
    for (min..max) |_| {
        var optional = try fst.clone(arena);
        try closure(W, &optional, .ques);
        try concat_mod.concat(W, &result, &optional);
    }

    return result;
}

// ── Tests ──

test "closure: star" {
    const W = @import("../weight.zig").TropicalWeight;
    const string = @import("../string.zig");
    const allocator = std.testing.allocator;

    var fst = try string.compileString(W, allocator, "a");
    defer fst.deinit();

    try closure(W, &fst, .star);

    // New start should be final (accepts empty string)
    try std.testing.expect(fst.isFinal(fst.start()));

    // New start should have epsilon arc to old start
    const start_arcs = fst.arcs(fst.start());
    try std.testing.expectEqual(@as(usize, 1), start_arcs.len);
    try std.testing.expect(start_arcs[0].isEpsilon());
}

test "closure: plus" {
    const W = @import("../weight.zig").TropicalWeight;
    const string = @import("../string.zig");
    const allocator = std.testing.allocator;

    var fst = try string.compileString(W, allocator, "a");
    defer fst.deinit();

    const old_start = fst.start();
    try closure(W, &fst, .plus);

    // Start state should not change
    try std.testing.expectEqual(old_start, fst.start());
    // Start should NOT be final (doesn't accept empty string)
    try std.testing.expect(!fst.isFinal(fst.start()));
}

test "closure: ques" {
    const W = @import("../weight.zig").TropicalWeight;
    const string = @import("../string.zig");
    const allocator = std.testing.allocator;

    var fst = try string.compileString(W, allocator, "a");
    defer fst.deinit();

    try closure(W, &fst, .ques);

    // New start should be final (accepts empty string)
    try std.testing.expect(fst.isFinal(fst.start()));
}
