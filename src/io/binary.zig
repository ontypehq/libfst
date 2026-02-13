const std = @import("std");
const fst_mod = @import("../fst.zig");
const weight_mod = @import("../weight.zig");

const Allocator = std.mem.Allocator;

/// Write a frozen Fst to a file in binary format.
/// The file is a direct dump of the contiguous byte buffer.
pub fn writeBinary(comptime W: type, fst: *const fst_mod.Fst(W), path: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(fst.bytes);
}

/// Read a frozen Fst from a binary file using mmap for zero-copy loading.
pub fn readBinary(comptime W: type, allocator: Allocator, path: []const u8) !fst_mod.Fst(W) {
    // For now, read the whole file into memory (mmap can be added later)
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    const size = stat.size;
    if (size < @sizeOf(fst_mod.Header)) return error.InvalidFormat;

    const bytes = try allocator.alignedAlloc(u8, .@"8", size);
    errdefer allocator.free(bytes);

    const read_n = try file.readAll(bytes);
    if (read_n != size) return error.UnexpectedEof;

    var result = try fst_mod.Fst(W).fromBytes(bytes);
    // Override source to owned since we allocated
    result.source = .owned;
    result.allocator = allocator;
    return result;
}

// ── Tests ──

test "binary: write and read roundtrip" {
    const W = weight_mod.TropicalWeight;
    const arc_mod = @import("../arc.zig");
    const A = arc_mod.Arc(W);
    const mutable_fst_mod = @import("../mutable-fst.zig");
    const allocator = std.testing.allocator;

    var mfst = mutable_fst_mod.MutableFst(W).init(allocator);
    defer mfst.deinit();

    _ = try mfst.addState();
    _ = try mfst.addState();
    _ = try mfst.addState();
    mfst.setStart(0);
    mfst.setFinal(2, W.init(1.5));
    try mfst.addArc(0, A.init(1, 2, W.init(0.5), 1));
    try mfst.addArc(1, A.init(3, 4, W.init(2.0), 2));

    var frozen = try fst_mod.Fst(W).fromMutable(allocator, &mfst);
    defer frozen.deinit();

    // Write to temp file
    const tmp_path = "/tmp/libfst_test_binary.fst";
    try writeBinary(W, &frozen, tmp_path);
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    // Read back
    var loaded = try readBinary(W, allocator, tmp_path);
    defer loaded.deinit();

    try std.testing.expectEqual(frozen.start(), loaded.start());
    try std.testing.expectEqual(frozen.numStates(), loaded.numStates());
    try std.testing.expectEqual(frozen.numArcs(0), loaded.numArcs(0));
    try std.testing.expectApproxEqAbs(
        frozen.finalWeight(2).value,
        loaded.finalWeight(2).value,
        0.001,
    );

    // Verify arc data
    const orig_arcs = frozen.arcs(0);
    const loaded_arcs = loaded.arcs(0);
    try std.testing.expectEqual(orig_arcs.len, loaded_arcs.len);
    try std.testing.expectEqual(orig_arcs[0].ilabel, loaded_arcs[0].ilabel);
}
