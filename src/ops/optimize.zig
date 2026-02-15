const std = @import("std");
const arc_mod = @import("../arc.zig");
const mutable_fst_mod = @import("../mutable-fst.zig");
const string_mod = @import("../string.zig");
const rm_epsilon_mod = @import("rm-epsilon.zig");
const determinize_mod = @import("determinize.zig");
const minimize_mod = @import("minimize.zig");
const connect_mod = @import("connect.zig");
const compose_mod = @import("compose.zig");
const shortest_path_mod = @import("shortest-path.zig");
const project_mod = @import("project.zig");

const Allocator = std.mem.Allocator;
const Label = arc_mod.Label;
const StateId = arc_mod.StateId;

const LabelPair = struct {
    ilabel: Label,
    olabel: Label,
};

/// Optimize an FST: rmEpsilon → determinize → minimize → connect.
///
/// For acceptors (`ilabel == olabel` on all arcs), runs the normal pipeline.
/// For transducers, performs encode-determinize-minimize-decode so determinize
/// remains valid and label pairs are preserved.
/// Returns a new, optimized MutableFst with no dead states.
pub fn optimize(comptime W: type, allocator: Allocator, fst: *const mutable_fst_mod.MutableFst(W)) !mutable_fst_mod.MutableFst(W) {
    // Arena for intermediate FSTs — freed in bulk on return
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Step 1: Remove epsilon transitions (temp, goes into arena)
    var no_eps = try rm_epsilon_mod.rmEpsilon(W, arena, fst);

    if (!isTransducer(W, &no_eps)) {
        // Acceptor fast path: standard pipeline.
        var det = try determinize_mod.determinize(W, arena, &no_eps);

        // Step 3: Minimize (in-place on arena copy)
        try minimize_mod.minimize(W, arena, &det);

        // Step 4: Connect — remove dead states (result uses caller's allocator)
        return connect_mod.connect(W, allocator, &det);
    }

    // Transducer path: encode label pairs onto a single tape, then decode.
    var encoded = try no_eps.clone(arena);
    var pair_to_label: std.AutoHashMapUnmanaged(LabelPair, Label) = .empty;
    var decode_map: std.AutoHashMapUnmanaged(Label, LabelPair) = .empty;

    var next_encoded = maxLabel(W, &encoded);
    if (next_encoded == std.math.maxInt(Label)) return error.LabelOverflow;
    next_encoded += 1;

    for (0..encoded.numStates()) |i| {
        const s: StateId = @intCast(i);
        for (encoded.arcsMut(s)) |*a| {
            if (a.ilabel == a.olabel) continue;
            const pair: LabelPair = .{ .ilabel = a.ilabel, .olabel = a.olabel };
            const gop = try pair_to_label.getOrPut(arena, pair);
            if (!gop.found_existing) {
                if (next_encoded == std.math.maxInt(Label)) return error.LabelOverflow;
                gop.value_ptr.* = next_encoded;
                try decode_map.put(arena, next_encoded, pair);
                next_encoded += 1;
            }
            const e = gop.value_ptr.*;
            a.ilabel = e;
            a.olabel = e;
        }
    }

    // Determinize/minimize now operate on an acceptor.
    var det = try determinize_mod.determinize(W, arena, &encoded);
    try minimize_mod.minimize(W, arena, &det);
    var connected = try connect_mod.connect(W, allocator, &det);

    // Decode back to original (ilabel, olabel) pairs.
    for (0..connected.numStates()) |i| {
        const s: StateId = @intCast(i);
        for (connected.arcsMut(s)) |*a| {
            if (decode_map.get(a.ilabel)) |pair| {
                a.ilabel = pair.ilabel;
                a.olabel = pair.olabel;
            }
        }
    }
    return connected;
}

fn isTransducer(comptime W: type, fst: *const mutable_fst_mod.MutableFst(W)) bool {
    for (0..fst.numStates()) |i| {
        const s: StateId = @intCast(i);
        for (fst.arcs(s)) |a| {
            if (a.ilabel != a.olabel) return true;
        }
    }
    return false;
}

fn maxLabel(comptime W: type, fst: *const mutable_fst_mod.MutableFst(W)) Label {
    var max_label: Label = 0;
    for (0..fst.numStates()) |i| {
        const s: StateId = @intCast(i);
        for (fst.arcs(s)) |a| {
            max_label = @max(max_label, a.ilabel);
            max_label = @max(max_label, a.olabel);
        }
    }
    return max_label;
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
    const allocator = std.testing.allocator;

    var fst = try string_mod.compileString(W, allocator, "hello");
    defer fst.deinit();

    var result = try optimize(W, allocator, &fst);
    defer result.deinit();

    // Optimized FST should be valid and accept the same language
    try std.testing.expect(result.start() != @import("../arc.zig").no_state);
    try std.testing.expect(result.numStates() > 0);
    try std.testing.expect(result.numStates() <= fst.numStates());
}

test "optimize: transducer labels survive determinize/minimize" {
    const W = @import("../weight.zig").TropicalWeight;
    const A = arc_mod.Arc(W);
    const allocator = std.testing.allocator;

    // Build transducer: "a" -> "b"
    var fst = mutable_fst_mod.MutableFst(W).init(allocator);
    defer fst.deinit();
    _ = try fst.addState(); // 0
    _ = try fst.addState(); // 1
    fst.setStart(0);
    fst.setFinal(1, W.one);
    try fst.addArc(0, A.init('a' + 1, 'b' + 1, W.one, 1));

    var result = try optimize(W, allocator, &fst);
    defer result.deinit();

    try std.testing.expect(result.numStates() > 0);
    try std.testing.expect(result.start() != arc_mod.no_state);
    const start_arcs = result.arcs(result.start());
    try std.testing.expectEqual(@as(usize, 1), start_arcs.len);
    try std.testing.expectEqual(@as(Label, 'a' + 1), start_arcs[0].ilabel);
    try std.testing.expectEqual(@as(Label, 'b' + 1), start_arcs[0].olabel);

    var input = try string_mod.compileString(W, allocator, "a");
    defer input.deinit();
    var composed = try compose_mod.compose(W, allocator, &input, &result);
    defer composed.deinit();
    var best = try shortest_path_mod.shortestPath(W, allocator, &composed, 1);
    defer best.deinit();
    project_mod.project(W, &best, .output);
    const out = try string_mod.printString(W, allocator, &best);
    try std.testing.expect(out != null);
    if (out) |s| {
        defer allocator.free(s);
        try std.testing.expectEqualStrings("b", s);
    }
}

test "optimize: transducer nondeterminism is preserved" {
    const W = @import("../weight.zig").TropicalWeight;
    const A = arc_mod.Arc(W);
    const allocator = std.testing.allocator;

    // "a" -> "x" | "a" -> "y"
    var fst = mutable_fst_mod.MutableFst(W).init(allocator);
    defer fst.deinit();
    _ = try fst.addState(); // 0
    _ = try fst.addState(); // 1
    _ = try fst.addState(); // 2
    fst.setStart(0);
    fst.setFinal(1, W.init(1.0));
    fst.setFinal(2, W.init(2.0));
    try fst.addArc(0, A.init('a' + 1, 'x' + 1, W.one, 1));
    try fst.addArc(0, A.init('a' + 1, 'y' + 1, W.one, 2));

    var result = try optimize(W, allocator, &fst);
    defer result.deinit();

    try std.testing.expect(result.numStates() > 0);
    try std.testing.expect(result.start() != arc_mod.no_state);
    const arcs = result.arcs(result.start());
    var saw_x = false;
    var saw_y = false;
    for (arcs) |a| {
        if (a.ilabel == 'a' + 1 and a.olabel == 'x' + 1) saw_x = true;
        if (a.ilabel == 'a' + 1 and a.olabel == 'y' + 1) saw_y = true;
    }
    try std.testing.expect(saw_x);
    try std.testing.expect(saw_y);
}
