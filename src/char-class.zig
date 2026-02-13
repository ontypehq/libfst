const std = @import("std");
const arc_mod = @import("arc.zig");
const mutable_fst_mod = @import("mutable-fst.zig");

const Label = arc_mod.Label;
const StateId = arc_mod.StateId;
const Allocator = std.mem.Allocator;

/// Build an acceptor FST that matches any single byte (0x00-0xFF).
/// Labels are byte_value + 1 (since 0 = epsilon).
pub fn byte(comptime W: type, allocator: Allocator) !mutable_fst_mod.MutableFst(W) {
    return singleCharClass(W, allocator, 0, 255);
}

/// Build an acceptor FST that matches any ASCII alpha character.
pub fn alpha(comptime W: type, allocator: Allocator) !mutable_fst_mod.MutableFst(W) {
    const A = arc_mod.Arc(W);
    var fst = mutable_fst_mod.MutableFst(W).init(allocator);
    errdefer fst.deinit();

    _ = try fst.addState(); // 0
    _ = try fst.addState(); // 1
    fst.setStart(0);
    fst.setFinal(1, W.one);

    // a-z
    for ('a'..'z' + 1) |c| {
        try fst.addArc(0, A.init(@intCast(c + 1), @intCast(c + 1), W.one, 1));
    }
    // A-Z
    for ('A'..'Z' + 1) |c| {
        try fst.addArc(0, A.init(@intCast(c + 1), @intCast(c + 1), W.one, 1));
    }

    return fst;
}

/// Build an acceptor FST that matches any ASCII digit character.
pub fn digit(comptime W: type, allocator: Allocator) !mutable_fst_mod.MutableFst(W) {
    return singleCharClass(W, allocator, '0', '9');
}

/// Build an acceptor for a single valid UTF-8 character (1-4 bytes).
/// This handles all valid UTF-8 byte sequences.
pub fn utf8Char(comptime W: type, allocator: Allocator) !mutable_fst_mod.MutableFst(W) {
    const A = arc_mod.Arc(W);
    var fst = mutable_fst_mod.MutableFst(W).init(allocator);
    errdefer fst.deinit();

    _ = try fst.addState(); // 0: start
    _ = try fst.addState(); // 1: final (after 1-byte char)
    _ = try fst.addState(); // 2: after first byte of 2-byte
    _ = try fst.addState(); // 3: after first byte of 3-byte
    _ = try fst.addState(); // 4: after second byte of 3-byte
    _ = try fst.addState(); // 5: after first byte of 4-byte
    _ = try fst.addState(); // 6: after second byte of 4-byte
    _ = try fst.addState(); // 7: after third byte of 4-byte

    fst.setStart(0);
    fst.setFinal(1, W.one);

    // 1-byte: 0x00-0x7F
    for (0..0x80) |c| {
        try fst.addArc(0, A.init(@intCast(c + 1), @intCast(c + 1), W.one, 1));
    }

    // 2-byte: 0xC2-0xDF followed by 0x80-0xBF
    for (0xC2..0xE0) |c| {
        try fst.addArc(0, A.init(@intCast(c + 1), @intCast(c + 1), W.one, 2));
    }
    for (0x80..0xC0) |c| {
        try fst.addArc(2, A.init(@intCast(c + 1), @intCast(c + 1), W.one, 1));
    }

    // 3-byte: 0xE0-0xEF followed by 2 continuation bytes
    for (0xE0..0xF0) |c| {
        try fst.addArc(0, A.init(@intCast(c + 1), @intCast(c + 1), W.one, 3));
    }
    for (0x80..0xC0) |c| {
        try fst.addArc(3, A.init(@intCast(c + 1), @intCast(c + 1), W.one, 4));
    }
    for (0x80..0xC0) |c| {
        try fst.addArc(4, A.init(@intCast(c + 1), @intCast(c + 1), W.one, 1));
    }

    // 4-byte: 0xF0-0xF4 followed by 3 continuation bytes
    for (0xF0..0xF5) |c| {
        try fst.addArc(0, A.init(@intCast(c + 1), @intCast(c + 1), W.one, 5));
    }
    for (0x80..0xC0) |c| {
        try fst.addArc(5, A.init(@intCast(c + 1), @intCast(c + 1), W.one, 6));
    }
    for (0x80..0xC0) |c| {
        try fst.addArc(6, A.init(@intCast(c + 1), @intCast(c + 1), W.one, 7));
    }
    for (0x80..0xC0) |c| {
        try fst.addArc(7, A.init(@intCast(c + 1), @intCast(c + 1), W.one, 1));
    }

    return fst;
}

/// Build a sigma-star acceptor: matches any sequence of bytes.
/// Single state with self-loops on all byte labels.
pub fn sigmaStar(comptime W: type, allocator: Allocator) !mutable_fst_mod.MutableFst(W) {
    const A = arc_mod.Arc(W);
    var fst = mutable_fst_mod.MutableFst(W).init(allocator);
    errdefer fst.deinit();

    _ = try fst.addState();
    fst.setStart(0);
    fst.setFinal(0, W.one);

    for (0..256) |c| {
        try fst.addArc(0, A.init(@intCast(c + 1), @intCast(c + 1), W.one, 0));
    }

    return fst;
}

/// Helper: build an acceptor for a range of byte values [lo, hi].
fn singleCharClass(comptime W: type, allocator: Allocator, lo: u8, hi: u8) !mutable_fst_mod.MutableFst(W) {
    const A = arc_mod.Arc(W);
    var fst = mutable_fst_mod.MutableFst(W).init(allocator);
    errdefer fst.deinit();

    _ = try fst.addState(); // 0
    _ = try fst.addState(); // 1
    fst.setStart(0);
    fst.setFinal(1, W.one);

    for (@as(u16, lo)..@as(u16, hi) + 1) |c| {
        const label: Label = @intCast(c + 1);
        try fst.addArc(0, A.init(label, label, W.one, 1));
    }

    return fst;
}

// ── Tests ──

test "char-class: byte" {
    const W = @import("weight.zig").TropicalWeight;
    const allocator = std.testing.allocator;

    var fst = try byte(W, allocator);
    defer fst.deinit();

    try std.testing.expectEqual(@as(usize, 2), fst.numStates());
    try std.testing.expectEqual(@as(usize, 256), fst.numArcs(0));
}

test "char-class: alpha" {
    const W = @import("weight.zig").TropicalWeight;
    const allocator = std.testing.allocator;

    var fst = try alpha(W, allocator);
    defer fst.deinit();

    try std.testing.expectEqual(@as(usize, 2), fst.numStates());
    try std.testing.expectEqual(@as(usize, 52), fst.numArcs(0)); // 26 + 26
}

test "char-class: digit" {
    const W = @import("weight.zig").TropicalWeight;
    const allocator = std.testing.allocator;

    var fst = try digit(W, allocator);
    defer fst.deinit();

    try std.testing.expectEqual(@as(usize, 2), fst.numStates());
    try std.testing.expectEqual(@as(usize, 10), fst.numArcs(0));
}

test "char-class: utf8Char" {
    const W = @import("weight.zig").TropicalWeight;
    const allocator = std.testing.allocator;

    var fst = try utf8Char(W, allocator);
    defer fst.deinit();

    // 8 states for the UTF-8 byte patterns
    try std.testing.expectEqual(@as(usize, 8), fst.numStates());
}

test "char-class: sigmaStar" {
    const W = @import("weight.zig").TropicalWeight;
    const allocator = std.testing.allocator;

    var fst = try sigmaStar(W, allocator);
    defer fst.deinit();

    try std.testing.expectEqual(@as(usize, 1), fst.numStates());
    try std.testing.expectEqual(@as(usize, 256), fst.numArcs(0));
    try std.testing.expect(fst.isFinal(0)); // accepts empty string too
}
