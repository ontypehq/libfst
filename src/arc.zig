const std = @import("std");

/// Arc label type. 0 = epsilon.
pub const Label = u32;

/// State identifier. max value = no_state sentinel.
pub const StateId = u32;

/// Epsilon label constant.
pub const epsilon: Label = 0;

/// Sentinel value indicating no state.
pub const no_state: StateId = std.math.maxInt(StateId);

/// A weighted arc in a finite state transducer.
/// Parameterized by weight type W.
pub fn Arc(comptime W: type) type {
    return struct {
        ilabel: Label,
        olabel: Label,
        weight: W,
        nextstate: StateId,

        const Self = @This();

        pub fn init(ilabel_: Label, olabel_: Label, weight_: W, nextstate_: StateId) Self {
            return .{
                .ilabel = ilabel_,
                .olabel = olabel_,
                .weight = weight_,
                .nextstate = nextstate_,
            };
        }

        /// Create an epsilon arc (both labels = 0).
        pub fn initEpsilon(weight_: W, nextstate_: StateId) Self {
            return init(epsilon, epsilon, weight_, nextstate_);
        }

        /// Check if this is an epsilon arc (both labels = 0).
        pub fn isEpsilon(self: Self) bool {
            return self.ilabel == epsilon and self.olabel == epsilon;
        }

        /// Compare arcs by ilabel for sorting.
        pub fn compareByIlabel(_: void, a: Self, b: Self) bool {
            if (a.ilabel != b.ilabel) return a.ilabel < b.ilabel;
            if (a.olabel != b.olabel) return a.olabel < b.olabel;
            return switch (W.compare(a.weight, b.weight)) {
                .lt => true,
                .gt => false,
                .eq => a.nextstate < b.nextstate,
            };
        }

        pub fn eql(a: Self, b: Self) bool {
            return a.ilabel == b.ilabel and
                a.olabel == b.olabel and
                a.weight.eql(b.weight) and
                a.nextstate == b.nextstate;
        }
    };
}

/// Standard arc with tropical weight.
pub const StdArc = Arc(@import("weight.zig").TropicalWeight);

/// Log arc with log weight.
pub const LogArc = Arc(@import("weight.zig").LogWeight);

// ── Tests ──

test "arc: basic construction" {
    const W = @import("weight.zig").TropicalWeight;
    const A = Arc(W);
    const a = A.init(1, 2, W.init(3.0), 4);
    try std.testing.expectEqual(@as(Label, 1), a.ilabel);
    try std.testing.expectEqual(@as(Label, 2), a.olabel);
    try std.testing.expect(a.weight.eql(W.init(3.0)));
    try std.testing.expectEqual(@as(StateId, 4), a.nextstate);
}

test "arc: epsilon" {
    const W = @import("weight.zig").TropicalWeight;
    const A = Arc(W);
    const a = A.initEpsilon(W.one, 1);
    try std.testing.expect(a.isEpsilon());
    try std.testing.expectEqual(epsilon, a.ilabel);
    try std.testing.expectEqual(epsilon, a.olabel);
}

test "arc: equality" {
    const W = @import("weight.zig").TropicalWeight;
    const A = Arc(W);
    const a = A.init(1, 2, W.init(3.0), 4);
    const b = A.init(1, 2, W.init(3.0), 4);
    const c = A.init(1, 2, W.init(5.0), 4);
    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
}

test "arc: sort by ilabel" {
    const W = @import("weight.zig").TropicalWeight;
    const A = Arc(W);
    var arcs = [_]A{
        A.init(3, 0, W.one, 1),
        A.init(1, 0, W.one, 2),
        A.init(2, 0, W.one, 0),
    };
    std.mem.sort(A, &arcs, {}, A.compareByIlabel);
    try std.testing.expectEqual(@as(Label, 1), arcs[0].ilabel);
    try std.testing.expectEqual(@as(Label, 2), arcs[1].ilabel);
    try std.testing.expectEqual(@as(Label, 3), arcs[2].ilabel);
}
