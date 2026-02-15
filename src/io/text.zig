const std = @import("std");
const arc_mod = @import("../arc.zig");
const mutable_fst_mod = @import("../mutable-fst.zig");
const sym_mod = @import("../sym.zig");

const Label = arc_mod.Label;
const StateId = arc_mod.StateId;
const epsilon = arc_mod.epsilon;
const no_state = arc_mod.no_state;
const Allocator = std.mem.Allocator;

/// Read a MutableFst from OpenFst AT&T text format.
///
/// Format:
///   src dest ilabel olabel [weight]   -- arc line
///   state [weight]                     -- final state line
///
/// The first src state encountered becomes the start state.
/// Labels are integers. Weight defaults to One if omitted.
pub fn readText(comptime W: type, allocator: Allocator, input: []const u8) !mutable_fst_mod.MutableFst(W) {
    const A = arc_mod.Arc(W);
    var fst = mutable_fst_mod.MutableFst(W).init(allocator);
    errdefer fst.deinit();

    var start_set = false;
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, &[_]u8{ '\r', ' ', '\t' });
        if (line.len == 0) continue;

        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const first = fields.next() orelse continue;
        const src = std.fmt.parseInt(StateId, first, 10) catch continue;

        // Ensure state exists
        while (fst.numStates() <= src) {
            _ = try fst.addState();
        }

        if (!start_set) {
            fst.setStart(src);
            start_set = true;
        }

        const second = fields.next() orelse {
            // Single field: final state with weight One
            fst.setFinal(src, W.one);
            continue;
        };

        // Try parsing second field as a state ID
        const maybe_dest = std.fmt.parseInt(StateId, second, 10) catch {
            // If it fails, treat as weight for final state
            const w = parseWeight(W, second) catch W.one;
            fst.setFinal(src, w);
            continue;
        };

        // Check if we have more fields (ilabel)
        const third = fields.next() orelse {
            // Two fields: "state weight" pattern
            const w = parseWeight(W, second) catch {
                // Or it could be "src dest" with no labels — unusual but handle
                // Treat second as dest, epsilon arc
                const dest = maybe_dest;
                while (fst.numStates() <= dest) {
                    _ = try fst.addState();
                }
                try fst.addArc(src, A.initEpsilon(W.one, dest));
                continue;
            };
            fst.setFinal(src, w);
            continue;
        };

        // We have at least 3 fields: src dest ilabel [olabel] [weight]
        const dest = maybe_dest;
        while (fst.numStates() <= dest) {
            _ = try fst.addState();
        }

        const ilabel = try std.fmt.parseInt(Label, third, 10);

        const fourth = fields.next();
        const fifth = fields.next();

        var olabel = ilabel;
        var w = W.one;

        if (fourth) |f4| {
            olabel = std.fmt.parseInt(Label, f4, 10) catch {
                // fourth is weight, olabel = ilabel
                olabel = ilabel;
                w = parseWeight(W, f4) catch W.one;
                try fst.addArc(src, A.init(ilabel, olabel, w, dest));
                continue;
            };

            if (fifth) |f5| {
                w = parseWeight(W, f5) catch W.one;
            }
        }

        try fst.addArc(src, A.init(ilabel, olabel, w, dest));
    }

    return fst;
}

fn parseWeight(comptime W: type, s: []const u8) !W {
    if (std.mem.eql(u8, s, "inf") or std.mem.eql(u8, s, "Infinity")) {
        return W.zero;
    }
    const v = try std.fmt.parseFloat(f64, s);
    return W.init(v);
}

/// Write a MutableFst to OpenFst AT&T text format.
pub fn writeText(comptime W: type, fst: *const mutable_fst_mod.MutableFst(W), writer: anytype) !void {
    const start_s = fst.start();
    if (start_s == no_state) return;

    // Write arcs from start state first (OpenFst convention)
    try writeStateArcs(W, fst, start_s, writer);

    // Write arcs from other states
    for (0..fst.numStates()) |i| {
        const s: StateId = @intCast(i);
        if (s == start_s) continue;
        try writeStateArcs(W, fst, s, writer);
    }

    // Write final states
    // Start state final weight first if applicable
    if (fst.isFinal(start_s)) {
        try writeFinalState(W, fst, start_s, writer);
    }
    for (0..fst.numStates()) |i| {
        const s: StateId = @intCast(i);
        if (s == start_s) continue;
        if (fst.isFinal(s)) {
            try writeFinalState(W, fst, s, writer);
        }
    }
}

fn writeStateArcs(comptime W: type, fst: *const mutable_fst_mod.MutableFst(W), s: StateId, writer: anytype) !void {
    for (fst.arcs(s)) |a| {
        try writer.print("{d}\t{d}\t{d}\t{d}", .{ s, a.nextstate, a.ilabel, a.olabel });
        if (!a.weight.eql(W.one)) {
            try writer.writeByte('\t');
            try writer.print("{f}", .{a.weight});
        }
        try writer.writeByte('\n');
    }
}

fn writeFinalState(comptime W: type, fst: *const mutable_fst_mod.MutableFst(W), s: StateId, writer: anytype) !void {
    try writer.print("{d}", .{s});
    const fw = fst.finalWeight(s);
    if (!fw.eql(W.one)) {
        try writer.writeByte('\t');
        try writer.print("{f}", .{fw});
    }
    try writer.writeByte('\n');
}

// ── Tests ──

test "text: roundtrip simple FST" {
    const W = @import("../weight.zig").TropicalWeight;
    const A = arc_mod.Arc(W);
    const allocator = std.testing.allocator;

    // Build an FST: 0 --(1:2/0.5)--> 1 --(3:4/1.0)--> 2(final, weight=0)
    var fst = mutable_fst_mod.MutableFst(W).init(allocator);
    defer fst.deinit();

    const s0 = try fst.addState();
    const s1 = try fst.addState();
    const s2 = try fst.addState();
    fst.setStart(s0);
    fst.setFinal(s2, W.one);
    try fst.addArc(s0, A.init(1, 2, W.init(0.5), s1));
    try fst.addArc(s1, A.init(3, 4, W.init(1.0), s2));

    // Write
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeText(W, &fst, &w);
    const output = w.buffered();

    // Read back
    var fst2 = try readText(W, allocator, output);
    defer fst2.deinit();

    try std.testing.expectEqual(3, fst2.numStates());
    try std.testing.expectEqual(0, fst2.start());
    try std.testing.expect(fst2.isFinal(2));
    try std.testing.expect(!fst2.isFinal(0));
    try std.testing.expectEqual(1, fst2.numArcs(0));
    try std.testing.expectEqual(1, fst2.numArcs(1));

    const a0 = fst2.arcs(0)[0];
    try std.testing.expectEqual(1, a0.ilabel);
    try std.testing.expectEqual(2, a0.olabel);
    try std.testing.expectEqual(1, a0.nextstate);
}

test "text: parse AT&T format" {
    const W = @import("../weight.zig").TropicalWeight;
    const allocator = std.testing.allocator;

    const input = "0\t1\t1\t2\t0.5\n1\t2\t3\t4\t1.0\n2\n";

    var fst = try readText(W, allocator, input);
    defer fst.deinit();

    try std.testing.expectEqual(3, fst.numStates());
    try std.testing.expectEqual(0, fst.start());
    try std.testing.expect(fst.isFinal(2));
    try std.testing.expectEqual(1, fst.numArcs(0));
}

test "text: final state with weight" {
    const W = @import("../weight.zig").TropicalWeight;
    const allocator = std.testing.allocator;

    const input = "0\t1\t1\t1\n1\t2.5\n";

    var fst = try readText(W, allocator, input);
    defer fst.deinit();

    try std.testing.expect(fst.isFinal(1));
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), fst.finalWeight(1).value, 0.001);
}
