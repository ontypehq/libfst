const std = @import("std");
const arc_mod = @import("../arc.zig");
const mutable_fst_mod = @import("../mutable-fst.zig");

const Label = arc_mod.Label;
const StateId = arc_mod.StateId;
const epsilon = arc_mod.epsilon;
const no_state = arc_mod.no_state;
const Allocator = std.mem.Allocator;

/// Pair of (label, FST) for subroutine substitution.
pub fn ReplacePair(comptime W: type) type {
    return struct {
        label: Label,
        fst: *const mutable_fst_mod.MutableFst(W),
    };
}

const DfsColor = enum { white, gray, black };

/// Replace operation: recursive subroutine substitution.
///
/// `root` is the top-level FST. `pairs` maps labels to sub-FSTs.
/// When the root FST has an arc with ilabel matching a pair's label,
/// that arc is replaced by the corresponding sub-FST.
///
/// Improvements over simple one-level replacement:
///   1. Cycle detection: builds a label dependency graph and uses DFS to
///      detect circular references. Returns error.CyclicDependency if found.
///   2. Topological ordering: sub-FSTs are expanded in dependency order
///      (leaves first), so nested references are fully resolved.
///   3. Recursive expansion: sub-FSTs containing labels that reference
///      other sub-FSTs are expanded transitively.
pub fn replace(comptime W: type, allocator: Allocator, root: *const mutable_fst_mod.MutableFst(W), pairs: []const ReplacePair(W)) !mutable_fst_mod.MutableFst(W) {
    if (root.start() == no_state) {
        return mutable_fst_mod.MutableFst(W).init(allocator);
    }

    if (pairs.len == 0) {
        return root.clone(allocator);
    }

    // Arena for all temporaries
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Build label -> index mapping
    var label_to_idx: std.AutoHashMapUnmanaged(Label, usize) = .empty;
    for (pairs, 0..) |pair, i| {
        try label_to_idx.put(arena, pair.label, i);
    }

    // 1. Build dependency graph: for each pair, which other pair labels does it reference?
    const dep_lists = try arena.alloc(std.ArrayList(usize), pairs.len);
    for (dep_lists) |*dl| dl.* = .empty;

    for (pairs, 0..) |pair, i| {
        const sub = pair.fst;
        if (sub.start() == no_state) continue;
        for (0..sub.numStates()) |si| {
            const s: StateId = @intCast(si);
            for (sub.arcs(s)) |a| {
                if (label_to_idx.get(a.ilabel)) |dep_idx| {
                    // Check if not already in dep list
                    var found = false;
                    for (dep_lists[i].items) |existing| {
                        if (existing == dep_idx) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        try dep_lists[i].append(arena, dep_idx);
                    }
                }
            }
        }
    }

    // 2. Cycle detection via DFS
    const colors = try arena.alloc(DfsColor, pairs.len);
    @memset(colors, .white);

    for (0..pairs.len) |i| {
        if (colors[i] == .white) {
            if (hasCycleDFS(dep_lists, colors, i)) return error.CyclicDependency;
        }
    }

    // 3. Topological sort (post-order DFS)
    const topo_order = try arena.alloc(usize, pairs.len);
    var topo_count: usize = 0;
    const visited = try arena.alloc(bool, pairs.len);
    @memset(visited, false);

    for (0..pairs.len) |i| {
        if (!visited[i]) {
            topoSortDFS(dep_lists, visited, topo_order, &topo_count, i);
        }
    }

    // 4. Expand sub-FSTs in topological order
    const expanded = try arena.alloc(?mutable_fst_mod.MutableFst(W), pairs.len);
    @memset(expanded, null);

    for (0..topo_count) |ti| {
        const idx = topo_order[ti];
        const sub = pairs[idx].fst;
        if (sub.start() == no_state) {
            expanded[idx] = mutable_fst_mod.MutableFst(W).init(arena);
            continue;
        }

        // Clone the sub-FST and inline any already-expanded dependencies
        var exp = try sub.clone(arena);
        try inlineAllRefs(W, arena, &exp, expanded, &label_to_idx);
        expanded[idx] = exp;
    }

    // 5. Inline all expanded sub-FSTs into the root
    var result = try root.clone(allocator);
    errdefer result.deinit();

    try inlineAllRefs(W, allocator, &result, expanded, &label_to_idx);

    return result;
}

fn hasCycleDFS(dep_lists: []const std.ArrayList(usize), colors: []DfsColor, node: usize) bool {
    colors[node] = .gray;
    for (dep_lists[node].items) |dep| {
        if (colors[dep] == .gray) return true; // back edge = cycle
        if (colors[dep] == .white) {
            if (hasCycleDFS(dep_lists, colors, dep)) return true;
        }
    }
    colors[node] = .black;
    return false;
}

fn topoSortDFS(dep_lists: []const std.ArrayList(usize), visited: []bool, order: []usize, count: *usize, node: usize) void {
    visited[node] = true;
    for (dep_lists[node].items) |dep| {
        if (!visited[dep]) {
            topoSortDFS(dep_lists, visited, order, count, dep);
        }
    }
    order[count.*] = node;
    count.* += 1;
}

/// Inline all label references in `fst` with expanded sub-FSTs.
fn inlineAllRefs(
    comptime W: type,
    allocator: Allocator,
    fst: *mutable_fst_mod.MutableFst(W),
    expanded: []const ?mutable_fst_mod.MutableFst(W),
    label_to_idx: *const std.AutoHashMapUnmanaged(Label, usize),
) !void {
    const A = arc_mod.Arc(W);

    // We need to process state by state, collecting arcs to replace.
    // Since adding states/arcs changes indices, we collect first then apply.
    const orig_num_states: StateId = @intCast(fst.numStates());

    // Collect replacement info: (src_state, arc_index, pair_index)
    const Replacement = struct { src: StateId, arc_idx: usize, pair_idx: usize };
    var replacements: std.ArrayList(Replacement) = .empty;
    defer replacements.deinit(allocator);

    for (0..orig_num_states) |i| {
        const s: StateId = @intCast(i);
        const state_arcs = fst.arcs(s);
        for (state_arcs, 0..) |a, ai| {
            if (label_to_idx.get(a.ilabel)) |idx| {
                if (expanded[idx] != null and expanded[idx].?.start() != no_state) {
                    try replacements.append(allocator, .{ .src = s, .arc_idx = ai, .pair_idx = idx });
                }
            }
        }
    }

    if (replacements.items.len == 0) return;

    // Group replacements by source state
    const ArcReplacement = struct { arc_idx: usize, pair_idx: usize };
    var states_with_replacements: std.AutoHashMapUnmanaged(StateId, std.ArrayList(ArcReplacement)) = .empty;
    defer {
        var it = states_with_replacements.valueIterator();
        while (it.next()) |v| v.deinit(allocator);
        states_with_replacements.deinit(allocator);
    }

    for (replacements.items) |r| {
        const entry = try states_with_replacements.getOrPut(allocator, r.src);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.append(allocator, .{ .arc_idx = r.arc_idx, .pair_idx = r.pair_idx });
    }

    // Process each state that has replacements
    var sit = states_with_replacements.iterator();
    while (sit.next()) |entry| {
        const src_state = entry.key_ptr.*;
        const state_replacements = entry.value_ptr.items;
        const orig_arcs = fst.arcs(src_state);

        // Build set of arc indices to replace
        var replace_set: std.AutoHashMapUnmanaged(usize, usize) = .empty;
        defer replace_set.deinit(allocator);
        for (state_replacements) |r| {
            try replace_set.put(allocator, r.arc_idx, r.pair_idx);
        }

        // Collect new arcs for this state
        var new_arcs: std.ArrayList(A) = .empty;
        defer new_arcs.deinit(allocator);

        for (orig_arcs, 0..) |a, ai| {
            if (replace_set.get(ai)) |pair_idx| {
                const sub = &(expanded[pair_idx].?);
                if (sub.start() == no_state) continue;

                // Embed sub-FST
                const offset: StateId = @intCast(fst.numStates());
                try fst.addStates(sub.numStates());

                // Copy sub-FST states and arcs
                for (0..sub.numStates()) |j| {
                    const sub_s: StateId = @intCast(j);
                    const dst: StateId = sub_s + offset;
                    for (sub.arcs(sub_s)) |sub_a| {
                        try fst.addArc(dst, A.init(
                            sub_a.ilabel,
                            sub_a.olabel,
                            sub_a.weight,
                            sub_a.nextstate + offset,
                        ));
                    }

                    // Connect sub-FST final states to arc's nextstate
                    const sub_fw = sub.finalWeight(sub_s);
                    if (!sub_fw.isZero()) {
                        try fst.addArc(dst, A.initEpsilon(
                            W.times(sub_fw, a.weight),
                            a.nextstate,
                        ));
                    }
                }

                // Epsilon arc from src to sub-FST start
                try new_arcs.append(allocator, A.initEpsilon(W.one, sub.start() + offset));
            } else {
                // Keep original arc
                try new_arcs.append(allocator, a);
            }
        }

        // Replace arcs on src_state
        fst.deleteArcs(src_state);
        for (new_arcs.items) |a| {
            try fst.addArc(src_state, a);
        }
    }
}

// ── Tests ──

test "replace: simple substitution" {
    const W = @import("../weight.zig").TropicalWeight;
    const A = arc_mod.Arc(W);
    const string = @import("../string.zig");
    const allocator = std.testing.allocator;

    // Root: 0 --(LABEL_X:LABEL_X)--> 1(final)
    const LABEL_X: Label = 1000;
    var root = mutable_fst_mod.MutableFst(W).init(allocator);
    defer root.deinit();
    _ = try root.addState();
    _ = try root.addState();
    root.setStart(0);
    root.setFinal(1, W.one);
    try root.addArc(0, A.init(LABEL_X, LABEL_X, W.one, 1));

    // Sub-FST: "ab"
    var sub = try string.compileString(W, allocator, "ab");
    defer sub.deinit();

    const pairs = [_]ReplacePair(W){
        .{ .label = LABEL_X, .fst = &sub },
    };

    var result = try replace(W, allocator, &root, &pairs);
    defer result.deinit();

    // Result should have more states (root + sub-FST)
    try std.testing.expect(result.numStates() > root.numStates());
    try std.testing.expect(result.start() != no_state);
}

test "replace: no matching labels" {
    const W = @import("../weight.zig").TropicalWeight;
    const string = @import("../string.zig");
    const allocator = std.testing.allocator;

    var root = try string.compileString(W, allocator, "abc");
    defer root.deinit();

    var sub = try string.compileString(W, allocator, "x");
    defer sub.deinit();

    const pairs = [_]ReplacePair(W){
        .{ .label = 9999, .fst = &sub },
    };

    var result = try replace(W, allocator, &root, &pairs);
    defer result.deinit();

    // Should be same as root (no replacements)
    try std.testing.expectEqual(root.numStates(), result.numStates());
}

test "replace: nested substitution" {
    const W = @import("../weight.zig").TropicalWeight;
    const A = arc_mod.Arc(W);
    const string = @import("../string.zig");
    const allocator = std.testing.allocator;

    const LABEL_A: Label = 1000;
    const LABEL_B: Label = 1001;

    // Root: 0 --(LABEL_A)--> 1(final)
    var root = mutable_fst_mod.MutableFst(W).init(allocator);
    defer root.deinit();
    _ = try root.addState();
    _ = try root.addState();
    root.setStart(0);
    root.setFinal(1, W.one);
    try root.addArc(0, A.init(LABEL_A, LABEL_A, W.one, 1));

    // Sub-A: 0 --(LABEL_B)--> 1(final)  (references LABEL_B)
    var sub_a = mutable_fst_mod.MutableFst(W).init(allocator);
    defer sub_a.deinit();
    _ = try sub_a.addState();
    _ = try sub_a.addState();
    sub_a.setStart(0);
    sub_a.setFinal(1, W.one);
    try sub_a.addArc(0, A.init(LABEL_B, LABEL_B, W.one, 1));

    // Sub-B: "xy"
    var sub_b = try string.compileString(W, allocator, "xy");
    defer sub_b.deinit();

    const pairs = [_]ReplacePair(W){
        .{ .label = LABEL_A, .fst = &sub_a },
        .{ .label = LABEL_B, .fst = &sub_b },
    };

    var result = try replace(W, allocator, &root, &pairs);
    defer result.deinit();

    // Should have expanded both levels
    try std.testing.expect(result.start() != no_state);
    // Root(2) + sub_a expanded(2 + sub_b(3)) = more than root + sub_a
    try std.testing.expect(result.numStates() > 4);
}

test "replace: cycle detection" {
    const W = @import("../weight.zig").TropicalWeight;
    const A = arc_mod.Arc(W);
    const allocator = std.testing.allocator;

    const LABEL_A: Label = 1000;
    const LABEL_B: Label = 1001;

    // Sub-A references LABEL_B
    var sub_a = mutable_fst_mod.MutableFst(W).init(allocator);
    defer sub_a.deinit();
    _ = try sub_a.addState();
    _ = try sub_a.addState();
    sub_a.setStart(0);
    sub_a.setFinal(1, W.one);
    try sub_a.addArc(0, A.init(LABEL_B, LABEL_B, W.one, 1));

    // Sub-B references LABEL_A (cycle!)
    var sub_b = mutable_fst_mod.MutableFst(W).init(allocator);
    defer sub_b.deinit();
    _ = try sub_b.addState();
    _ = try sub_b.addState();
    sub_b.setStart(0);
    sub_b.setFinal(1, W.one);
    try sub_b.addArc(0, A.init(LABEL_A, LABEL_A, W.one, 1));

    // Root
    var root = mutable_fst_mod.MutableFst(W).init(allocator);
    defer root.deinit();
    _ = try root.addState();
    _ = try root.addState();
    root.setStart(0);
    root.setFinal(1, W.one);
    try root.addArc(0, A.init(LABEL_A, LABEL_A, W.one, 1));

    const pairs = [_]ReplacePair(W){
        .{ .label = LABEL_A, .fst = &sub_a },
        .{ .label = LABEL_B, .fst = &sub_b },
    };

    const result = replace(W, allocator, &root, &pairs);
    try std.testing.expectError(error.CyclicDependency, result);
}

test "replace: empty root" {
    const W = @import("../weight.zig").TropicalWeight;
    const string = @import("../string.zig");
    const allocator = std.testing.allocator;

    var root = mutable_fst_mod.MutableFst(W).init(allocator);
    defer root.deinit();

    var sub = try string.compileString(W, allocator, "x");
    defer sub.deinit();

    const pairs = [_]ReplacePair(W){
        .{ .label = 1000, .fst = &sub },
    };

    var result = try replace(W, allocator, &root, &pairs);
    defer result.deinit();
    try std.testing.expectEqual(no_state, result.start());
}
