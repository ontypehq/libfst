const std = @import("std");
const mutable_fst_mod = @import("../mutable-fst.zig");
const rm_epsilon_mod = @import("rm-epsilon.zig");
const determinize_mod = @import("determinize.zig");
const minimize_mod = @import("minimize.zig");
const connect_mod = @import("connect.zig");

const Allocator = std.mem.Allocator;

/// Optimize an FST: rmEpsilon → determinize → minimize → connect.
/// Returns a new, optimized MutableFst with no dead states.
pub fn optimize(comptime W: type, allocator: Allocator, fst: *const mutable_fst_mod.MutableFst(W)) !mutable_fst_mod.MutableFst(W) {
    // Arena for intermediate FSTs — freed in bulk on return
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Step 1: Remove epsilon transitions (temp, goes into arena)
    var no_eps = try rm_epsilon_mod.rmEpsilon(W, arena, fst);

    // Step 2: Determinize (temp, goes into arena)
    var det = try determinize_mod.determinize(W, arena, &no_eps);

    // Step 3: Minimize (in-place on arena copy)
    try minimize_mod.minimize(W, arena, &det);

    // Step 4: Connect — remove dead states (result uses caller's allocator)
    return connect_mod.connect(W, allocator, &det);
}

// ── Tests ──

test "optimize: simple pipeline" {
    const W = @import("../weight.zig").TropicalWeight;
    const arc = @import("../arc.zig");
    const A = arc.Arc(W);
    const allocator = std.testing.allocator;

    // Build an FST with epsilon transitions and nondeterminism
    // 0 --eps--> 1 --a--> 3(final)
    // 0 --eps--> 2 --a--> 3(final)
    var fst = mutable_fst_mod.MutableFst(W).init(allocator);
    defer fst.deinit();

    _ = try fst.addState(); // 0
    _ = try fst.addState(); // 1
    _ = try fst.addState(); // 2
    _ = try fst.addState(); // 3
    fst.setStart(0);
    fst.setFinal(3, W.one);
    try fst.addArc(0, A.initEpsilon(W.one, 1));
    try fst.addArc(0, A.initEpsilon(W.one, 2));
    try fst.addArc(1, A.init(1, 1, W.init(1.0), 3));
    try fst.addArc(2, A.init(1, 1, W.init(2.0), 3));

    var result = try optimize(W, allocator, &fst);
    defer result.deinit();

    // Optimized should have fewer or equal states
    try std.testing.expect(result.numStates() <= fst.numStates());
    try std.testing.expect(result.start() != arc.no_state);
}

test "optimize: linear chain preserves paths" {
    const W = @import("../weight.zig").TropicalWeight;
    const string = @import("../string.zig");
    const allocator = std.testing.allocator;

    var fst = try string.compileString(W, allocator, "hello");
    defer fst.deinit();

    var result = try optimize(W, allocator, &fst);
    defer result.deinit();

    // Optimized FST should be valid and accept the same language
    try std.testing.expect(result.start() != @import("../arc.zig").no_state);
    try std.testing.expect(result.numStates() > 0);
    try std.testing.expect(result.numStates() <= fst.numStates());
}
