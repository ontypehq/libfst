const std = @import("std");
const arc_mod = @import("arc.zig");
const mutable_fst_mod = @import("mutable-fst.zig");

const Label = arc_mod.Label;
const StateId = arc_mod.StateId;
const no_state = arc_mod.no_state;
const Allocator = std.mem.Allocator;

/// Compile a byte string into a linear-chain FST (acceptor).
/// Each byte becomes a label on an arc. Both ilabel and olabel are the same.
pub fn compileString(comptime W: type, allocator: Allocator, input: []const u8) !mutable_fst_mod.MutableFst(W) {
    return compileStringTransducer(W, allocator, input, input);
}

/// Compile a pair of byte strings into a linear-chain transducer.
/// Input string maps to output string. If lengths differ, shorter side
/// is padded with epsilon transitions.
pub fn compileStringTransducer(comptime W: type, allocator: Allocator, input: []const u8, output: []const u8) !mutable_fst_mod.MutableFst(W) {
    const A = arc_mod.Arc(W);
    var fst = mutable_fst_mod.MutableFst(W).init(allocator);
    errdefer fst.deinit();

    const max_len = @max(input.len, output.len);
    if (max_len == 0) {
        // Empty string: single final state
        const s = try fst.addState();
        fst.setStart(s);
        fst.setFinal(s, W.one);
        return fst;
    }

    // Create states: one per character + final
    try fst.addStates(max_len + 1);
    fst.setStart(0);
    fst.setFinal(@intCast(max_len), W.one);

    for (0..max_len) |i| {
        const il: Label = if (i < input.len) @as(Label, input[i]) + 1 else arc_mod.epsilon;
        const ol: Label = if (i < output.len) @as(Label, output[i]) + 1 else arc_mod.epsilon;
        try fst.addArc(@intCast(i), A.init(il, ol, W.one, @intCast(i + 1)));
    }

    return fst;
}

/// Extract a string from a linear-chain acceptor FST.
/// Returns null if the FST is not a simple linear chain.
pub fn printString(comptime W: type, allocator: Allocator, fst: *const mutable_fst_mod.MutableFst(W)) !?[]u8 {
    const start_s = fst.start();
    if (start_s == no_state) return null;

    var result = std.ArrayListUnmanaged(u8){};
    errdefer result.deinit(allocator);

    var current = start_s;
    while (true) {
        if (fst.isFinal(current)) {
            if (fst.numArcs(current) == 0) break;
        }
        const state_arcs = fst.arcs(current);
        if (state_arcs.len != 1) return null; // Not a linear chain
        const a = state_arcs[0];
        if (a.ilabel != arc_mod.epsilon) {
            // Label = byte + 1 (since 0 = epsilon)
            try result.append(allocator, @intCast(a.ilabel - 1));
        }
        current = a.nextstate;
        if (current == no_state) return null;
    }

    return try result.toOwnedSlice(allocator);
}

// ── Tests ──

test "string: compile and print roundtrip" {
    const W = @import("weight.zig").TropicalWeight;
    const allocator = std.testing.allocator;

    var fst = try compileString(W, allocator, "hello");
    defer fst.deinit();

    try std.testing.expectEqual(@as(usize, 6), fst.numStates()); // 5 chars + final
    try std.testing.expectEqual(@as(StateId, 0), fst.start());
    try std.testing.expect(fst.isFinal(5));

    const s = try printString(W, allocator, &fst);
    defer allocator.free(s.?);
    try std.testing.expectEqualStrings("hello", s.?);
}

test "string: empty string" {
    const W = @import("weight.zig").TropicalWeight;
    const allocator = std.testing.allocator;

    var fst = try compileString(W, allocator, "");
    defer fst.deinit();

    try std.testing.expectEqual(@as(usize, 1), fst.numStates());
    try std.testing.expect(fst.isFinal(0));

    const s = try printString(W, allocator, &fst);
    defer allocator.free(s.?);
    try std.testing.expectEqual(@as(usize, 0), s.?.len);
}

test "string: transducer different lengths" {
    const W = @import("weight.zig").TropicalWeight;
    const allocator = std.testing.allocator;

    var fst = try compileStringTransducer(W, allocator, "ab", "xyz");
    defer fst.deinit();

    // max(2, 3) = 3 arcs, 4 states
    try std.testing.expectEqual(@as(usize, 4), fst.numStates());
    try std.testing.expect(fst.isFinal(3));

    // First arc: a -> x
    const a0 = fst.arcs(0)[0];
    try std.testing.expectEqual(@as(Label, 'a' + 1), a0.ilabel);
    try std.testing.expectEqual(@as(Label, 'x' + 1), a0.olabel);

    // Third arc: eps -> z (input exhausted)
    const a2 = fst.arcs(2)[0];
    try std.testing.expectEqual(arc_mod.epsilon, a2.ilabel);
    try std.testing.expectEqual(@as(Label, 'z' + 1), a2.olabel);
}

test "string: UTF-8 bytes" {
    const W = @import("weight.zig").TropicalWeight;
    const allocator = std.testing.allocator;

    const input = "中"; // 3 UTF-8 bytes: 0xE4, 0xB8, 0xAD
    var fst = try compileString(W, allocator, input);
    defer fst.deinit();

    try std.testing.expectEqual(@as(usize, 4), fst.numStates()); // 3 bytes + final

    const s = try printString(W, allocator, &fst);
    defer allocator.free(s.?);
    try std.testing.expectEqualStrings(input, s.?);
}
