const std = @import("std");
const arc_mod = @import("../arc.zig");
const mutable_fst_mod = @import("../mutable-fst.zig");

const Label = arc_mod.Label;
const StateId = arc_mod.StateId;
const epsilon = arc_mod.epsilon;
const no_state = arc_mod.no_state;
const Allocator = std.mem.Allocator;

fn toWeight(comptime W: type, value: anytype) W {
    const T = @TypeOf(value);
    if (T == W) return value;
    if (T == f64) return W.init(value);
    if (T == f32) return W.init(@as(f64, value));
    if (T == f16) return W.init(@as(f64, value));
    @compileError("compose: unsupported arc weight type");
}

/// Compose two FSTs: result accepts string pairs (x, z) such that
/// there exists y where (x, y) ∈ fst1 and (y, z) ∈ fst2.
///
/// Uses epsilon-sequencing filter to handle epsilon transitions:
/// Filter state tracks which FST is allowed to consume epsilons.
///   filter=0: both can match or fst1 consumes eps
///   filter=1: only fst2 can consume eps
///   filter=2: only fst1 can consume eps
pub fn compose(comptime W: type, allocator: Allocator, fst1: anytype, fst2: anytype) !mutable_fst_mod.MutableFst(W) {
    const A = arc_mod.Arc(W);

    if (fst1.start() == no_state or fst2.start() == no_state) {
        return mutable_fst_mod.MutableFst(W).init(allocator);
    }

    // Arena for all temporaries — freed in bulk on return
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var result = mutable_fst_mod.MutableFst(W).init(allocator);
    errdefer result.deinit();

    // State in composition: (state1, state2, filter)
    // filter ∈ {0, 1, 2} for epsilon-sequencing
    const StateTuple = struct {
        s1: StateId,
        s2: StateId,
        filter: u8,

        fn toKey(self: @This()) u64 {
            return @as(u64, self.s1) |
                (@as(u64, self.s2) << 21) |
                (@as(u64, self.filter) << 42);
        }
    };

    var state_map = std.AutoHashMapUnmanaged(u64, StateId){};

    var queue = std.ArrayListUnmanaged(StateTuple){};

    // Initial state
    const init_tuple = StateTuple{ .s1 = fst1.start(), .s2 = fst2.start(), .filter = 0 };
    const init_state = try result.addState();
    result.setStart(init_state);
    try state_map.put(arena, init_tuple.toKey(), init_state);
    try queue.append(arena, init_tuple);

    var qi: usize = 0;
    while (qi < queue.items.len) : (qi += 1) {
        const t = queue.items[qi];
        const current = state_map.get(t.toKey()).?;

        // Final weight
        const fw1 = fst1.finalWeight(t.s1);
        const fw2 = fst2.finalWeight(t.s2);
        if (!fw1.isZero() and !fw2.isZero()) {
            result.setFinal(current, W.times(fw1, fw2));
        }

        // Get or create state for a tuple
        const getOrCreate = struct {
            fn call(
                res: *mutable_fst_mod.MutableFst(W),
                smap: *std.AutoHashMapUnmanaged(u64, StateId),
                q: *std.ArrayListUnmanaged(StateTuple),
                alloc: Allocator,
                tuple: StateTuple,
            ) !StateId {
                const key = tuple.toKey();
                if (smap.get(key)) |existing| return existing;
                const ns = try res.addState();
                try smap.put(alloc, key, ns);
                try q.append(alloc, tuple);
                return ns;
            }
        }.call;

        // Match non-epsilon arcs: olabel of fst1 == ilabel of fst2
        for (fst1.arcs(t.s1)) |a1| {
            if (a1.olabel == epsilon) continue;
            for (fst2.arcs(t.s2)) |a2| {
                if (a2.ilabel == a1.olabel) {
                    const next = StateTuple{ .s1 = a1.nextstate, .s2 = a2.nextstate, .filter = 0 };
                    const ns = try getOrCreate(&result, &state_map, &queue, arena, next);
                    try result.addArc(current, A.init(
                        a1.ilabel,
                        a2.olabel,
                        W.times(toWeight(W, a1.weight), toWeight(W, a2.weight)),
                        ns,
                    ));
                }
            }
        }

        // Epsilon handling with sequencing filter
        if (t.filter != 1) {
            // fst1 can consume output epsilon
            for (fst1.arcs(t.s1)) |a1| {
                if (a1.olabel == epsilon) {
                    const new_filter: u8 = if (t.filter == 0) 2 else t.filter;
                    const next = StateTuple{ .s1 = a1.nextstate, .s2 = t.s2, .filter = new_filter };
                    const ns = try getOrCreate(&result, &state_map, &queue, arena, next);
                    try result.addArc(current, A.init(a1.ilabel, epsilon, toWeight(W, a1.weight), ns));
                }
            }
        }

        if (t.filter != 2) {
            // fst2 can consume input epsilon
            for (fst2.arcs(t.s2)) |a2| {
                if (a2.ilabel == epsilon) {
                    const new_filter: u8 = if (t.filter == 0) 1 else t.filter;
                    const next = StateTuple{ .s1 = t.s1, .s2 = a2.nextstate, .filter = new_filter };
                    const ns = try getOrCreate(&result, &state_map, &queue, arena, next);
                    try result.addArc(current, A.init(epsilon, a2.olabel, toWeight(W, a2.weight), ns));
                }
            }
        }

        // Both consume epsilon simultaneously (filter reset)
        if (t.filter == 0) {
            for (fst1.arcs(t.s1)) |a1| {
                if (a1.olabel != epsilon) continue;
                for (fst2.arcs(t.s2)) |a2| {
                    if (a2.ilabel != epsilon) continue;
                    const next = StateTuple{ .s1 = a1.nextstate, .s2 = a2.nextstate, .filter = 0 };
                    const ns = try getOrCreate(&result, &state_map, &queue, arena, next);
                    try result.addArc(current, A.init(
                        a1.ilabel,
                        a2.olabel,
                        W.times(toWeight(W, a1.weight), toWeight(W, a2.weight)),
                        ns,
                    ));
                }
            }
        }
    }

    return result;
}

// ── Tests ──

test "compose: simple transducer chain" {
    const W = @import("../weight.zig").TropicalWeight;
    const string = @import("../string.zig");
    const allocator = std.testing.allocator;

    // fst1: "a" -> "b" (byte-level transducer)
    var fst1 = try string.compileStringTransducer(W, allocator, "a", "b");
    defer fst1.deinit();

    // fst2: "b" -> "c"
    var fst2 = try string.compileStringTransducer(W, allocator, "b", "c");
    defer fst2.deinit();

    var result = try compose(W, allocator, &fst1, &fst2);
    defer result.deinit();

    // Result should map "a" -> "c"
    try std.testing.expect(result.start() != no_state);
    try std.testing.expect(result.numStates() > 0);

    // Follow the path: start --a:c--> final
    var found_final = false;
    var s = result.start();
    while (true) {
        if (result.isFinal(s)) {
            found_final = true;
            break;
        }
        const state_arcs = result.arcs(s);
        if (state_arcs.len == 0) break;
        s = state_arcs[0].nextstate;
    }
    try std.testing.expect(found_final);
}

test "compose: identity" {
    const W = @import("../weight.zig").TropicalWeight;
    const A = arc_mod.Arc(W);
    const allocator = std.testing.allocator;

    // fst: acceptor for "ab"
    var fst = mutable_fst_mod.MutableFst(W).init(allocator);
    defer fst.deinit();
    _ = try fst.addState(); // 0
    _ = try fst.addState(); // 1
    _ = try fst.addState(); // 2
    fst.setStart(0);
    fst.setFinal(2, W.one);
    try fst.addArc(0, A.init(1, 1, W.one, 1));
    try fst.addArc(1, A.init(2, 2, W.one, 2));

    // Compose with itself should accept "ab"
    var result = try compose(W, allocator, &fst, &fst);
    defer result.deinit();

    try std.testing.expect(result.start() != no_state);
    try std.testing.expect(result.numStates() >= 3);
}

test "compose: empty intersection" {
    const W = @import("../weight.zig").TropicalWeight;
    const string = @import("../string.zig");
    const allocator = std.testing.allocator;

    // fst1: "a" -> "a"
    var fst1 = try string.compileString(W, allocator, "a");
    defer fst1.deinit();

    // fst2: "b" -> "b"
    var fst2 = try string.compileString(W, allocator, "b");
    defer fst2.deinit();

    var result = try compose(W, allocator, &fst1, &fst2);
    defer result.deinit();

    // No path should reach a final state
    if (result.start() != no_state) {
        var has_final = false;
        for (0..result.numStates()) |i| {
            if (result.isFinal(@intCast(i))) {
                has_final = true;
                break;
            }
        }
        try std.testing.expect(!has_final);
    }
}
