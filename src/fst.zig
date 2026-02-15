const std = @import("std");
const arc_mod = @import("arc.zig");
const weight_mod = @import("weight.zig");
const mutable_fst_mod = @import("mutable-fst.zig");

const Label = arc_mod.Label;
const StateId = arc_mod.StateId;
const no_state = arc_mod.no_state;
const Allocator = std.mem.Allocator;

/// Magic number for FST binary format: "FST!"
pub const MAGIC: u32 = 0x46535421;
pub const VERSION: u16 = 1;

/// Packed state entry in the frozen layout.
pub const StateEntry = extern struct {
    arc_offset: u32,
    num_arcs: u32,
    final_weight: f64,
};

/// Packed arc in the frozen layout.
pub const PackedArc = extern struct {
    ilabel: u32,
    olabel: u32,
    weight: f64,
    nextstate: u32,
};

/// File header for the frozen FST binary format.
pub const Header = extern struct {
    magic: u32,
    version: u16,
    weight_type: u8,
    flags: u8,
    num_states: u32,
    num_arcs: u32,
    start_state: u32,
    _padding: u32 = 0, // pad to 24 bytes for 8-byte alignment
};

/// Weight type discriminator for serialization.
pub fn weightTypeId(comptime W: type) u8 {
    if (W == weight_mod.TropicalWeight) return 0;
    if (W == weight_mod.LogWeight) return 1;
    @compileError("unsupported weight type");
}

/// Frozen, immutable FST with contiguous memory layout.
/// Thread-safe for concurrent reads. Supports zero-copy mmap loading.
pub fn Fst(comptime W: type) type {
    return struct {
        bytes: []align(8) const u8,
        source: Source,
        allocator: ?Allocator,

        const Self = @This();

        pub const Source = enum {
            owned,
            mmap,
        };

        fn header(self: *const Self) *const Header {
            return @alignCast(@ptrCast(self.bytes.ptr));
        }

        fn stateTable(self: *const Self) []const StateEntry {
            const h = self.header();
            const offset = @sizeOf(Header);
            const ptr: [*]const StateEntry = @alignCast(@ptrCast(self.bytes.ptr + offset));
            return ptr[0..h.num_states];
        }

        fn arcTable(self: *const Self) []const PackedArc {
            const h = self.header();
            const offset = @sizeOf(Header) + @as(usize, h.num_states) * @sizeOf(StateEntry);
            const ptr: [*]const PackedArc = @alignCast(@ptrCast(self.bytes.ptr + offset));
            return ptr[0..h.num_arcs];
        }

        // ── Query ──

        pub fn start(self: *const Self) StateId {
            return self.header().start_state;
        }

        pub fn numStates(self: *const Self) u32 {
            return self.header().num_states;
        }

        pub fn numArcs(self: *const Self, s: StateId) u32 {
            return self.stateTable()[s].num_arcs;
        }

        pub fn finalWeight(self: *const Self, s: StateId) W {
            return W.init(self.stateTable()[s].final_weight);
        }

        pub fn isFinal(self: *const Self, s: StateId) bool {
            return !self.finalWeight(s).isZero();
        }

        pub fn arcs(self: *const Self, s: StateId) []const PackedArc {
            const entry = self.stateTable()[s];
            return self.arcTable()[entry.arc_offset..][0..entry.num_arcs];
        }

        /// Binary search for an arc with the given ilabel from state s.
        /// Arcs must be sorted by ilabel (guaranteed by freeze).
        pub fn findArc(self: *const Self, s: StateId, ilabel: Label) ?PackedArc {
            const state_arcs = self.arcs(s);
            var lo: usize = 0;
            var hi: usize = state_arcs.len;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                if (state_arcs[mid].ilabel < ilabel) {
                    lo = mid + 1;
                } else if (state_arcs[mid].ilabel > ilabel) {
                    hi = mid;
                } else {
                    return state_arcs[mid];
                }
            }
            return null;
        }

        // ── Lifecycle ──

        /// Freeze a MutableFst into an immutable Fst with contiguous layout.
        pub fn fromMutable(allocator: Allocator, mutable: *mutable_fst_mod.MutableFst(W)) !Self {
            // Sort all arcs by ilabel for binary search
            mutable.sortAllArcs();

            const num_states: u32 = @intCast(mutable.numStates());
            var total_arcs: u32 = 0;
            for (0..num_states) |i| {
                total_arcs += @intCast(mutable.numArcs(@intCast(i)));
            }

            const buf_size = @sizeOf(Header) +
                @as(usize, num_states) * @sizeOf(StateEntry) +
                @as(usize, total_arcs) * @sizeOf(PackedArc);

            const bytes = try allocator.alignedAlloc(u8, .@"8", buf_size);
            errdefer allocator.free(bytes);

            // Write header
            const hdr: *Header = @alignCast(@ptrCast(bytes.ptr));
            hdr.* = .{
                .magic = MAGIC,
                .version = VERSION,
                .weight_type = weightTypeId(W),
                .flags = 0,
                .num_states = num_states,
                .num_arcs = total_arcs,
                .start_state = mutable.start(),
            };

            // Write state table
            const state_ptr: [*]StateEntry = @alignCast(@ptrCast(bytes.ptr + @sizeOf(Header)));
            var arc_offset: u32 = 0;
            for (0..num_states) |i| {
                const s: StateId = @intCast(i);
                const n: u32 = @intCast(mutable.numArcs(s));
                state_ptr[i] = .{
                    .arc_offset = arc_offset,
                    .num_arcs = n,
                    .final_weight = mutable.finalWeight(s).value,
                };
                arc_offset += n;
            }

            // Write arc table
            const arc_base = @sizeOf(Header) + @as(usize, num_states) * @sizeOf(StateEntry);
            const arc_ptr: [*]PackedArc = @alignCast(@ptrCast(bytes.ptr + arc_base));
            var ai: usize = 0;
            for (0..num_states) |i| {
                for (mutable.arcs(@intCast(i))) |a| {
                    arc_ptr[ai] = .{
                        .ilabel = a.ilabel,
                        .olabel = a.olabel,
                        .weight = a.weight.value,
                        .nextstate = a.nextstate,
                    };
                    ai += 1;
                }
            }

            return .{
                .bytes = bytes,
                .source = .owned,
                .allocator = allocator,
            };
        }

        /// Load from pre-existing bytes (zero-copy, e.g. from mmap).
        pub fn fromBytes(bytes: []align(8) const u8) !Self {
            if (bytes.len < @sizeOf(Header)) return error.InvalidFormat;
            const hdr: *const Header = @alignCast(@ptrCast(bytes.ptr));
            if (hdr.magic != MAGIC) return error.InvalidMagic;
            if (hdr.version != VERSION) return error.UnsupportedVersion;
            if (hdr.weight_type != weightTypeId(W)) return error.WeightTypeMismatch;

            // Validate buffer size matches declared num_states/num_arcs
            const expected_size = @sizeOf(Header) +
                @as(usize, hdr.num_states) * @sizeOf(StateEntry) +
                @as(usize, hdr.num_arcs) * @sizeOf(PackedArc);
            if (bytes.len < expected_size) return error.InvalidFormat;

            // Validate start state
            if (hdr.num_states > 0 and hdr.start_state != no_state and
                hdr.start_state >= hdr.num_states) return error.InvalidFormat;

            return .{
                .bytes = bytes,
                .source = .mmap,
                .allocator = null,
            };
        }

        pub fn deinit(self: *Self) void {
            switch (self.source) {
                .owned => {
                    if (self.allocator) |alloc| {
                        alloc.free(self.bytes);
                    }
                },
                .mmap => {
                    // mmap'd memory is not owned by us
                },
            }
        }
    };
}

pub const StdFst = Fst(weight_mod.TropicalWeight);
pub const LogFst = Fst(weight_mod.LogWeight);

// ── Tests ──

test "fst: freeze and query" {
    const W = weight_mod.TropicalWeight;
    const A = arc_mod.Arc(W);
    const allocator = std.testing.allocator;

    var mfst = mutable_fst_mod.MutableFst(W).init(allocator);
    defer mfst.deinit();

    _ = try mfst.addState(); // 0
    _ = try mfst.addState(); // 1
    _ = try mfst.addState(); // 2
    mfst.setStart(0);
    mfst.setFinal(2, W.one);
    try mfst.addArc(0, A.init(1, 2, W.init(0.5), 1));
    try mfst.addArc(1, A.init(3, 4, W.init(1.0), 2));

    var frozen = try Fst(W).fromMutable(allocator, &mfst);
    defer frozen.deinit();

    try std.testing.expectEqual(0, frozen.start());
    try std.testing.expectEqual(3, frozen.numStates());
    try std.testing.expect(frozen.isFinal(2));
    try std.testing.expect(!frozen.isFinal(0));
    try std.testing.expectEqual(1, frozen.numArcs(0));
    try std.testing.expectEqual(1, frozen.numArcs(1));
    try std.testing.expectEqual(0, frozen.numArcs(2));
}

test "fst: findArc binary search" {
    const W = weight_mod.TropicalWeight;
    const A = arc_mod.Arc(W);
    const allocator = std.testing.allocator;

    var mfst = mutable_fst_mod.MutableFst(W).init(allocator);
    defer mfst.deinit();

    _ = try mfst.addState();
    _ = try mfst.addState();
    mfst.setStart(0);
    mfst.setFinal(1, W.one);
    try mfst.addArc(0, A.init(5, 5, W.one, 1));
    try mfst.addArc(0, A.init(10, 10, W.one, 1));
    try mfst.addArc(0, A.init(15, 15, W.one, 1));

    var frozen = try Fst(W).fromMutable(allocator, &mfst);
    defer frozen.deinit();

    // Find existing arc
    const found = frozen.findArc(0, 10);
    try std.testing.expect(found != null);
    try std.testing.expectEqual(10, found.?.ilabel);

    // Find non-existing arc
    const not_found = frozen.findArc(0, 7);
    try std.testing.expect(not_found == null);
}

test "fst: fromBytes roundtrip" {
    const W = weight_mod.TropicalWeight;
    const A = arc_mod.Arc(W);
    const allocator = std.testing.allocator;

    var mfst = mutable_fst_mod.MutableFst(W).init(allocator);
    defer mfst.deinit();

    _ = try mfst.addState();
    _ = try mfst.addState();
    mfst.setStart(0);
    mfst.setFinal(1, W.init(2.5));
    try mfst.addArc(0, A.init(1, 2, W.init(3.0), 1));

    var frozen1 = try Fst(W).fromMutable(allocator, &mfst);
    defer frozen1.deinit();

    // Load from same bytes
    var frozen2 = try Fst(W).fromBytes(frozen1.bytes);
    // Don't deinit frozen2 since it borrows from frozen1

    try std.testing.expectEqual(frozen1.start(), frozen2.start());
    try std.testing.expectEqual(frozen1.numStates(), frozen2.numStates());
    try std.testing.expectApproxEqAbs(
        frozen1.finalWeight(1).value,
        frozen2.finalWeight(1).value,
        0.001,
    );
    _ = &frozen2;
}
