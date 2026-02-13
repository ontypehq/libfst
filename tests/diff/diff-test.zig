const std = @import("std");
const libfst = @import("libfst");

const W = libfst.TropicalWeight;
const MutableFst = libfst.MutableFst(W);
const A = libfst.Arc(W);
const Label = libfst.Label;
const StateId = libfst.StateId;
const no_state = libfst.no_state;
const io_text = libfst.io_text;

const compose = libfst.ops.compose.compose;
const determinize = libfst.ops.determinize.determinize;
const minimize = libfst.ops.minimize.minimize;
const optimize = libfst.ops.optimize.optimize;
const union_ = libfst.ops.union_.union_;
const concat = libfst.ops.concat.concat;
const closure_op = libfst.ops.closure.closure;
const invert = libfst.ops.invert.invert;
const project = libfst.ops.project.project;
const shortestPath = libfst.ops.shortest_path.shortestPath;
const difference = libfst.ops.difference.difference;
const rmEpsilon = libfst.ops.rm_epsilon.rmEpsilon;

const CORPUS_DIR = "tests/corpus/";

/// Read an AT&T text file and return a MutableFst.
fn readCorpusFile(allocator: std.mem.Allocator, filename: []const u8) !MutableFst {
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}{s}", .{ CORPUS_DIR, filename }) catch unreachable;
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        std.debug.print("Cannot open {s}: {any}\n", .{ path, err });
        return err;
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 64 * 1024 * 1024);
    defer allocator.free(content);

    return io_text.readText(W, allocator, content);
}

/// BFS-based graph isomorphism check for FSTs.
///
/// Verifies that two FSTs have identical structure by building a state mapping
/// via BFS traversal: compares arc labels, weights (with tolerance), and
/// final weights at each pair of corresponding states.
///
/// Both FSTs should be determinized/minimized (canonical form) for this to work.
fn fstEquivalent(allocator: std.mem.Allocator, a: *const MutableFst, b: *const MutableFst) !bool {
    // Both empty
    if (a.start() == no_state and b.start() == no_state) return true;
    if (a.start() == no_state or b.start() == no_state) return false;

    // Quick structural check (necessary but not sufficient)
    if (a.numStates() != b.numStates()) return false;
    if (a.totalArcs() != b.totalArcs()) return false;

    // BFS isomorphism: map a's states to b's states
    var a_to_b = std.AutoHashMap(StateId, StateId).init(allocator);
    defer a_to_b.deinit();
    var b_to_a = std.AutoHashMap(StateId, StateId).init(allocator);
    defer b_to_a.deinit();

    var queue = std.ArrayListUnmanaged(StateId).empty;
    defer queue.deinit(allocator);

    try a_to_b.put(a.start(), b.start());
    try b_to_a.put(b.start(), a.start());
    try queue.append(allocator, a.start());

    while (queue.items.len > 0) {
        const sa = queue.orderedRemove(0);
        const sb = a_to_b.get(sa).?;

        // Compare final weights
        const fw_a = a.finalWeight(sa).value;
        const fw_b = b.finalWeight(sb).value;
        if (std.math.isInf(fw_a) != std.math.isInf(fw_b)) return false;
        if (!std.math.isInf(fw_a) and @abs(fw_a - fw_b) > 1e-5) return false;

        // Get and sort arcs by (ilabel, olabel) for deterministic comparison
        const arcs_a = a.arcs(sa);
        const arcs_b = b.arcs(sb);
        if (arcs_a.len != arcs_b.len) return false;

        // Sort both arc slices
        const sorted_a = try allocator.alloc(A, arcs_a.len);
        defer allocator.free(sorted_a);
        @memcpy(sorted_a, arcs_a);
        std.mem.sort(A, sorted_a, {}, arcLessThan);

        const sorted_b = try allocator.alloc(A, arcs_b.len);
        defer allocator.free(sorted_b);
        @memcpy(sorted_b, arcs_b);
        std.mem.sort(A, sorted_b, {}, arcLessThan);

        for (sorted_a, sorted_b) |aa, ab| {
            if (aa.ilabel != ab.ilabel) return false;
            if (aa.olabel != ab.olabel) return false;

            // Compare weights with tolerance
            const wa = aa.weight.value;
            const wb = ab.weight.value;
            if (std.math.isInf(wa) != std.math.isInf(wb)) return false;
            if (!std.math.isInf(wa) and @abs(wa - wb) > 1e-5) return false;

            // Map next states
            if (a_to_b.get(aa.nextstate)) |mapped_b| {
                if (mapped_b != ab.nextstate) return false;
            } else {
                // Check reverse mapping consistency
                if (b_to_a.contains(ab.nextstate)) return false;
                try a_to_b.put(aa.nextstate, ab.nextstate);
                try b_to_a.put(ab.nextstate, aa.nextstate);
                try queue.append(allocator, aa.nextstate);
            }
        }
    }

    // Verify all states were visited
    return a_to_b.count() == a.numStates();
}

fn arcLessThan(_: void, lhs: A, rhs: A) bool {
    if (lhs.ilabel != rhs.ilabel) return lhs.ilabel < rhs.ilabel;
    if (lhs.olabel != rhs.olabel) return lhs.olabel < rhs.olabel;
    return lhs.weight.value < rhs.weight.value;
}

fn expectEquivalent(allocator: std.mem.Allocator, result: *const MutableFst, golden: *const MutableFst) !void {
    if (!try fstEquivalent(allocator, result, golden)) {
        std.debug.print("\n=== RESULT ({d} states, {d} arcs) ===\n", .{ result.numStates(), result.totalArcs() });
        var buf_r = std.ArrayListUnmanaged(u8).empty;
        defer buf_r.deinit(allocator);
        try io_text.writeText(W, result, buf_r.writer(allocator));
        std.debug.print("{s}\n", .{buf_r.items});

        std.debug.print("=== GOLDEN ({d} states, {d} arcs) ===\n", .{ golden.numStates(), golden.totalArcs() });
        var buf_g = std.ArrayListUnmanaged(u8).empty;
        defer buf_g.deinit(allocator);
        try io_text.writeText(W, golden, buf_g.writer(allocator));
        std.debug.print("{s}\n", .{buf_g.items});

        return error.TestExpectedEqual;
    }
}

// ── Diff tests ──
// These tests compare libfst operations against Pynini golden outputs.
// If corpus files don't exist, tests are skipped (not failed).

test "diff: compose" {
    const allocator = std.testing.allocator;
    const input1 = readCorpusFile(allocator, "compose.input1.att") catch return;
    defer @constCast(&input1).deinit();
    const input2 = readCorpusFile(allocator, "compose.input2.att") catch return;
    defer @constCast(&input2).deinit();
    const golden = readCorpusFile(allocator, "compose.golden.att") catch return;
    defer @constCast(&golden).deinit();

    var result = try compose(W, allocator, &input1, &input2);
    defer result.deinit();

    var opt = try optimize(W, allocator, &result);
    defer opt.deinit();

    try expectEquivalent(allocator, &opt, &golden);
}

test "diff: determinize" {
    const allocator = std.testing.allocator;
    const input = readCorpusFile(allocator, "determinize.input.att") catch return;
    defer @constCast(&input).deinit();
    const golden = readCorpusFile(allocator, "determinize.golden.att") catch return;
    defer @constCast(&golden).deinit();

    var result = try determinize(W, allocator, &input);
    defer result.deinit();

    try expectEquivalent(allocator, &result, &golden);
}

test "diff: union" {
    const allocator = std.testing.allocator;
    const input1 = readCorpusFile(allocator, "union.input1.att") catch return;
    defer @constCast(&input1).deinit();
    const input2 = readCorpusFile(allocator, "union.input2.att") catch return;
    defer @constCast(&input2).deinit();
    const golden = readCorpusFile(allocator, "union.golden.att") catch return;
    defer @constCast(&golden).deinit();

    var result = try input1.clone(allocator);
    defer result.deinit();
    try union_(W, &result, &input2);

    var opt = try optimize(W, allocator, &result);
    defer opt.deinit();

    try expectEquivalent(allocator, &opt, &golden);
}

test "diff: concat" {
    const allocator = std.testing.allocator;
    const input1 = readCorpusFile(allocator, "concat.input1.att") catch return;
    defer @constCast(&input1).deinit();
    const input2 = readCorpusFile(allocator, "concat.input2.att") catch return;
    defer @constCast(&input2).deinit();
    const golden = readCorpusFile(allocator, "concat.golden.att") catch return;
    defer @constCast(&golden).deinit();

    var result = try input1.clone(allocator);
    defer result.deinit();
    try concat(W, &result, &input2);

    var opt = try optimize(W, allocator, &result);
    defer opt.deinit();

    try expectEquivalent(allocator, &opt, &golden);
}

test "diff: closure star" {
    const allocator = std.testing.allocator;
    const input = readCorpusFile(allocator, "closure_star.input.att") catch return;
    defer @constCast(&input).deinit();
    const golden = readCorpusFile(allocator, "closure_star.golden.att") catch return;
    defer @constCast(&golden).deinit();

    var result = try input.clone(allocator);
    defer result.deinit();
    try closure_op(W, &result, .star);

    var opt = try optimize(W, allocator, &result);
    defer opt.deinit();

    try expectEquivalent(allocator, &opt, &golden);
}

test "diff: invert" {
    const allocator = std.testing.allocator;
    const input = readCorpusFile(allocator, "invert.input.att") catch return;
    defer @constCast(&input).deinit();
    const golden = readCorpusFile(allocator, "invert.golden.att") catch return;
    defer @constCast(&golden).deinit();

    var result = try input.clone(allocator);
    defer result.deinit();
    invert(W, &result);

    try expectEquivalent(allocator, &result, &golden);
}

test "diff: project input" {
    const allocator = std.testing.allocator;
    const input = readCorpusFile(allocator, "project.input.att") catch return;
    defer @constCast(&input).deinit();
    const golden = readCorpusFile(allocator, "project_input.golden.att") catch return;
    defer @constCast(&golden).deinit();

    var result = try input.clone(allocator);
    defer result.deinit();
    project(W, &result, .input);

    try expectEquivalent(allocator, &result, &golden);
}

test "diff: project output" {
    const allocator = std.testing.allocator;
    const input = readCorpusFile(allocator, "project.input.att") catch return;
    defer @constCast(&input).deinit();
    const golden = readCorpusFile(allocator, "project_output.golden.att") catch return;
    defer @constCast(&golden).deinit();

    var result = try input.clone(allocator);
    defer result.deinit();
    project(W, &result, .output);

    try expectEquivalent(allocator, &result, &golden);
}

test "diff: shortest path" {
    const allocator = std.testing.allocator;
    const input = readCorpusFile(allocator, "shortest_path.input.att") catch return;
    defer @constCast(&input).deinit();
    const golden = readCorpusFile(allocator, "shortest_path.golden.att") catch return;
    defer @constCast(&golden).deinit();

    var result = try shortestPath(W, allocator, &input, 2);
    defer result.deinit();

    // Shortest path preserves epsilon chains differently across implementations.
    // Optimize both sides for canonical comparison.
    var opt_result = try optimize(W, allocator, &result);
    defer opt_result.deinit();
    var opt_golden = try optimize(W, allocator, &golden);
    defer opt_golden.deinit();

    try expectEquivalent(allocator, &opt_result, &opt_golden);
}

test "diff: difference" {
    const allocator = std.testing.allocator;
    const input1 = readCorpusFile(allocator, "difference.input1.att") catch return;
    defer @constCast(&input1).deinit();
    const input2 = readCorpusFile(allocator, "difference.input2.att") catch return;
    defer @constCast(&input2).deinit();
    const golden = readCorpusFile(allocator, "difference.golden.att") catch return;
    defer @constCast(&golden).deinit();

    var result = try difference(W, allocator, &input1, &input2);
    defer result.deinit();

    var opt = try optimize(W, allocator, &result);
    defer opt.deinit();

    try expectEquivalent(allocator, &opt, &golden);
}

test "diff: optimize" {
    const allocator = std.testing.allocator;
    const input = readCorpusFile(allocator, "optimize.input.att") catch return;
    defer @constCast(&input).deinit();
    const golden = readCorpusFile(allocator, "optimize.golden.att") catch return;
    defer @constCast(&golden).deinit();

    var result = try optimize(W, allocator, &input);
    defer result.deinit();

    try expectEquivalent(allocator, &result, &golden);
}
