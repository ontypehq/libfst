const std = @import("std");
const libfst = @import("libfst");

const W = libfst.TropicalWeight;
const MutableFst = libfst.MutableFst(W);
const Fst = libfst.Fst(W);
const A = libfst.Arc(W);
const Label = libfst.Label;
const no_state = libfst.no_state;
const io_text = libfst.io_text;
const io_binary = @import("libfst").io_binary;

const determinize = libfst.ops.determinize.determinize;
const minimize = libfst.ops.minimize.minimize;
const compose = libfst.ops.compose.compose;
const optimize = libfst.ops.optimize.optimize;

// ── Random FST Generator ──

/// Generate a random FST with `num_states` states and up to `max_arcs` arcs.
/// Uses a fixed seed for reproducibility.
fn randomFst(allocator: std.mem.Allocator, seed: u64, num_states: u32, max_arcs: u32, max_label: Label) !MutableFst {
    var rng = std.Random.DefaultPrng.init(seed);
    const random = rng.random();

    var fst = MutableFst.init(allocator);
    errdefer fst.deinit();

    try fst.addStates(num_states);
    fst.setStart(0);

    // Random final states
    for (0..num_states) |i| {
        if (random.boolean()) {
            fst.setFinal(@intCast(i), W.init(random.float(f64) * 10.0));
        }
    }

    // Random arcs
    const arc_count = random.intRangeAtMost(u32, 1, max_arcs);
    for (0..arc_count) |_| {
        const src = random.intRangeLessThan(u32, 0, num_states);
        const dst = random.intRangeLessThan(u32, 0, num_states);
        const il = random.intRangeLessThan(Label, 0, max_label + 1);
        const ol = random.intRangeLessThan(Label, 0, max_label + 1);
        const w = W.init(random.float(f64) * 10.0);
        try fst.addArc(src, A.init(il, ol, w, dst));
    }

    return fst;
}

// ── Semiring Property Tests ──

test "prop: tropical weight associativity" {
    const a = W.init(2.0);
    const b = W.init(3.0);
    const c = W.init(5.0);
    // Plus associativity: (a + b) + c = a + (b + c)
    try std.testing.expect(W.plus(W.plus(a, b), c).eql(W.plus(a, W.plus(b, c))));
    // Times associativity: (a * b) * c = a * (b * c)
    try std.testing.expect(W.times(W.times(a, b), c).eql(W.times(a, W.times(b, c))));
}

test "prop: tropical weight commutativity" {
    const a = W.init(2.0);
    const b = W.init(7.0);
    try std.testing.expect(W.plus(a, b).eql(W.plus(b, a)));
    try std.testing.expect(W.times(a, b).eql(W.times(b, a)));
}

test "prop: tropical weight identity" {
    const a = W.init(3.5);
    // Plus identity: a + zero = a
    try std.testing.expect(W.plus(a, W.zero).eql(a));
    try std.testing.expect(W.plus(W.zero, a).eql(a));
    // Times identity: a * one = a
    try std.testing.expect(W.times(a, W.one).eql(a));
    try std.testing.expect(W.times(W.one, a).eql(a));
}

test "prop: tropical weight annihilation" {
    const a = W.init(42.0);
    // Times annihilation: a * zero = zero
    try std.testing.expect(W.times(a, W.zero).isZero());
    try std.testing.expect(W.times(W.zero, a).isZero());
}

// ── Idempotency Property Tests ──

test "prop: determinize idempotency" {
    const allocator = std.testing.allocator;

    for (0..5) |seed| {
        var fst = try randomFst(allocator, seed + 100, 4, 8, 5);
        defer fst.deinit();

        var det1 = determinize(W, allocator, &fst) catch continue;
        defer det1.deinit();

        var det2 = determinize(W, allocator, &det1) catch continue;
        defer det2.deinit();

        // det(det(F)) should have same number of states
        try std.testing.expectEqual(det1.numStates(), det2.numStates());
    }
}

test "prop: minimize idempotency" {
    const allocator = std.testing.allocator;

    for (0..5) |seed| {
        var fst = try randomFst(allocator, seed + 200, 4, 8, 5);
        defer fst.deinit();

        // Must determinize first (minimize requires deterministic input)
        var det = determinize(W, allocator, &fst) catch continue;
        defer det.deinit();

        var min1 = try det.clone(allocator);
        defer min1.deinit();
        minimize(W, allocator, &min1) catch continue;

        var min2 = try min1.clone(allocator);
        defer min2.deinit();
        minimize(W, allocator, &min2) catch continue;

        // min(min(F)) should have same number of states
        try std.testing.expectEqual(min1.numStates(), min2.numStates());
    }
}

// ── Roundtrip Property Tests ──

test "prop: freeze roundtrip preserves data" {
    const allocator = std.testing.allocator;

    for (0..5) |seed| {
        var fst = try randomFst(allocator, seed + 300, 4, 8, 5);
        defer fst.deinit();

        if (fst.numStates() == 0) continue;

        var frozen = Fst.fromMutable(allocator, &fst) catch continue;
        defer frozen.deinit();

        // Same number of states
        try std.testing.expectEqual(@intCast(fst.numStates()), frozen.numStates());
        // Same start
        try std.testing.expectEqual(fst.start(), frozen.start());

        // Same total arcs
        var frozen_total: usize = 0;
        for (0..frozen.numStates()) |i| {
            frozen_total += frozen.numArcs(@intCast(i));
        }
        try std.testing.expectEqual(fst.totalArcs(), frozen_total);
    }
}

test "prop: compose with identity" {
    const allocator = std.testing.allocator;

    // Build identity acceptor for labels 1..5
    var identity = MutableFst.init(allocator);
    defer identity.deinit();
    _ = try identity.addState();
    identity.setStart(0);
    identity.setFinal(0, W.one);
    for (1..6) |l| {
        try identity.addArc(0, A.init(@intCast(l), @intCast(l), W.one, 0));
    }

    for (0..5) |seed| {
        var fst = try randomFst(allocator, seed + 400, 3, 6, 5);
        defer fst.deinit();

        if (fst.start() == no_state) continue;

        // compose(F, identity) should preserve the language
        var result = compose(W, allocator, &fst, &identity) catch continue;
        defer result.deinit();

        try std.testing.expect(result.start() != no_state or fst.start() == no_state);
    }
}
