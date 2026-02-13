const std = @import("std");
const arc_mod = @import("../arc.zig");
const mutable_fst_mod = @import("../mutable-fst.zig");

const Label = arc_mod.Label;
const StateId = arc_mod.StateId;
const epsilon = arc_mod.epsilon;
const no_state = arc_mod.no_state;
const Allocator = std.mem.Allocator;

/// Minimize a deterministic FST in-place using Hopcroft-style partition refinement.
/// The FST must be deterministic (run determinize first).
/// Combines equivalent states that have the same future behavior.
pub fn minimize(comptime W: type, allocator: Allocator, fst: *mutable_fst_mod.MutableFst(W)) !void {
    const num = fst.numStates();
    if (num <= 1) return;

    // Arena for all temporaries — freed in bulk on return
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Sort all arcs first for consistent comparison
    fst.sortAllArcs();

    // Step 1: Compute initial partition.
    // Group states by their "signature": (final_weight, sorted arcs pattern)
    var partition = try arena.alloc(u32, num);

    var sig_map = std.StringHashMapUnmanaged(u32){};

    var next_class: u32 = 0;
    var sig_buf = std.ArrayListUnmanaged(u8){};

    for (0..num) |i| {
        const s: StateId = @intCast(i);
        sig_buf.clearRetainingCapacity();

        // Encode final weight
        const fw = fst.finalWeight(s);
        const fw_bits: u64 = @bitCast(fw.value);
        try sig_buf.appendSlice(arena, std.mem.asBytes(&fw_bits));

        // Encode arcs
        for (fst.arcs(s)) |a| {
            try sig_buf.appendSlice(arena, std.mem.asBytes(&a.ilabel));
            try sig_buf.appendSlice(arena, std.mem.asBytes(&a.olabel));
            const w_bits: u64 = @bitCast(a.weight.value);
            try sig_buf.appendSlice(arena, std.mem.asBytes(&w_bits));
        }

        const key = try arena.dupe(u8, sig_buf.items);
        if (sig_map.get(sig_buf.items)) |class| {
            partition[i] = class;
        } else {
            try sig_map.put(arena, key, next_class);
            partition[i] = next_class;
            next_class += 1;
        }
    }

    // Step 2: Refine partition until stable.
    // Iteratively split classes based on transition targets' classes.
    var changed = true;
    var new_partition = try arena.alloc(u32, num);

    while (changed) {
        changed = false;

        // Clear sig map for this iteration (arena doesn't need individual frees)
        sig_map.clearRetainingCapacity();
        next_class = 0;

        for (0..num) |i| {
            const s: StateId = @intCast(i);
            sig_buf.clearRetainingCapacity();

            // Encode current class
            try sig_buf.appendSlice(arena, std.mem.asBytes(&partition[i]));

            // Encode final weight
            const fw = fst.finalWeight(s);
            const fw_bits: u64 = @bitCast(fw.value);
            try sig_buf.appendSlice(arena, std.mem.asBytes(&fw_bits));

            // Encode (label, target_class) pairs for each arc
            for (fst.arcs(s)) |a| {
                try sig_buf.appendSlice(arena, std.mem.asBytes(&a.ilabel));
                try sig_buf.appendSlice(arena, std.mem.asBytes(&a.olabel));
                const w_bits: u64 = @bitCast(a.weight.value);
                try sig_buf.appendSlice(arena, std.mem.asBytes(&w_bits));
                const target_class = partition[a.nextstate];
                try sig_buf.appendSlice(arena, std.mem.asBytes(&target_class));
            }

            const key = try arena.dupe(u8, sig_buf.items);
            if (sig_map.get(sig_buf.items)) |class| {
                new_partition[i] = class;
            } else {
                try sig_map.put(arena, key, next_class);
                new_partition[i] = next_class;
                next_class += 1;
            }
        }

        // Check if partition changed
        for (0..num) |i| {
            if (partition[i] != new_partition[i]) {
                changed = true;
                break;
            }
        }
        @memcpy(partition, new_partition);
    }

    // Step 3: Build minimized FST by merging states in same partition class.
    // Map each class to a representative state.
    const num_classes = next_class;
    if (num_classes == num) return; // Already minimal

    var class_to_state = try arena.alloc(StateId, num_classes);
    @memset(class_to_state, no_state);

    // Map old states to new state IDs
    var mapping = try arena.alloc(StateId, num);

    var new_state_count: StateId = 0;
    for (0..num) |i| {
        const class = partition[i];
        if (class_to_state[class] == no_state) {
            class_to_state[class] = new_state_count;
            new_state_count += 1;
        }
        mapping[i] = class_to_state[class];
    }

    try fst.remapStates(mapping);
}

// ── Tests ──

test "minimize: already minimal" {
    const W = @import("../weight.zig").TropicalWeight;
    const string = @import("../string.zig");
    const allocator = std.testing.allocator;

    var fst = try string.compileString(W, allocator, "abc");
    defer fst.deinit();

    const orig_states = fst.numStates();
    try minimize(W, allocator, &fst);
    try std.testing.expectEqual(orig_states, fst.numStates());
}

test "minimize: merge equivalent states" {
    const W = @import("../weight.zig").TropicalWeight;
    const A = arc_mod.Arc(W);
    const allocator = std.testing.allocator;

    // Two states (1 and 2) that are equivalent: both final with same weight, no arcs
    // 0 --a--> 1(final)
    // 0 --b--> 2(final)
    var fst = mutable_fst_mod.MutableFst(W).init(allocator);
    defer fst.deinit();

    _ = try fst.addState(); // 0
    _ = try fst.addState(); // 1
    _ = try fst.addState(); // 2
    fst.setStart(0);
    fst.setFinal(1, W.one);
    fst.setFinal(2, W.one);
    try fst.addArc(0, A.init(1, 1, W.one, 1));
    try fst.addArc(0, A.init(2, 2, W.one, 2));

    try minimize(W, allocator, &fst);

    // States 1 and 2 should be merged
    try std.testing.expectEqual(@as(usize, 2), fst.numStates());
}

test "minimize: idempotent" {
    const W = @import("../weight.zig").TropicalWeight;
    const A = arc_mod.Arc(W);
    const allocator = std.testing.allocator;

    var fst = mutable_fst_mod.MutableFst(W).init(allocator);
    defer fst.deinit();

    _ = try fst.addState();
    _ = try fst.addState();
    _ = try fst.addState();
    fst.setStart(0);
    fst.setFinal(1, W.one);
    fst.setFinal(2, W.one);
    try fst.addArc(0, A.init(1, 1, W.one, 1));
    try fst.addArc(0, A.init(2, 2, W.one, 2));

    try minimize(W, allocator, &fst);
    const n1 = fst.numStates();

    try minimize(W, allocator, &fst);
    const n2 = fst.numStates();

    try std.testing.expectEqual(n1, n2);
}
