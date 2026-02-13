const std = @import("std");
const math = std.math;

/// Tropical semiring: Plus = min, Times = +, Zero = +inf, One = 0
pub const TropicalWeight = struct {
    value: f64,

    pub const zero = TropicalWeight{ .value = math.inf(f64) };
    pub const one = TropicalWeight{ .value = 0.0 };

    pub fn init(v: f64) TropicalWeight {
        return .{ .value = v };
    }

    pub fn plus(a: TropicalWeight, b: TropicalWeight) TropicalWeight {
        return .{ .value = @min(a.value, b.value) };
    }

    pub fn times(a: TropicalWeight, b: TropicalWeight) TropicalWeight {
        // If either is zero (inf), result is zero (inf)
        if (a.isZero() or b.isZero()) return zero;
        return .{ .value = a.value + b.value };
    }

    pub fn eql(a: TropicalWeight, b: TropicalWeight) bool {
        if (a.isZero() and b.isZero()) return true;
        return a.value == b.value;
    }

    pub fn isZero(self: TropicalWeight) bool {
        return math.isInf(self.value);
    }

    pub fn compare(a: TropicalWeight, b: TropicalWeight) math.Order {
        // Lower weight = better in tropical semiring
        return math.order(a.value, b.value);
    }

    pub fn reverse(self: TropicalWeight) TropicalWeight {
        return self;
    }

    pub fn hash(self: TropicalWeight) u64 {
        if (self.isZero()) return 0xFFFFFFFFFFFFFFFF;
        return @bitCast(self.value);
    }

    pub fn read(reader: anytype) !TropicalWeight {
        const v = try reader.readInt(u64, .little);
        return .{ .value = @bitCast(v) };
    }

    pub fn write(self: TropicalWeight, writer: anytype) !void {
        const bits: u64 = @bitCast(self.value);
        try writer.writeInt(u64, bits, .little);
    }

    pub fn format(self: TropicalWeight, w: anytype) !void {
        if (self.isZero()) {
            try w.writeAll("inf");
        } else {
            try w.print("{d}", .{self.value});
        }
    }
};

/// Log semiring: Plus = -log(e^-a + e^-b), Times = +, Zero = +inf, One = 0
pub const LogWeight = struct {
    value: f64,

    pub const zero = LogWeight{ .value = math.inf(f64) };
    pub const one = LogWeight{ .value = 0.0 };

    pub fn init(v: f64) LogWeight {
        return .{ .value = v };
    }

    pub fn plus(a: LogWeight, b: LogWeight) LogWeight {
        if (a.isZero()) return b;
        if (b.isZero()) return a;
        if (a.value < b.value) {
            return .{ .value = a.value - std.math.log1p(@exp(a.value - b.value)) };
        } else {
            return .{ .value = b.value - std.math.log1p(@exp(b.value - a.value)) };
        }
    }

    pub fn times(a: LogWeight, b: LogWeight) LogWeight {
        if (a.isZero() or b.isZero()) return zero;
        return .{ .value = a.value + b.value };
    }

    pub fn eql(a: LogWeight, b: LogWeight) bool {
        if (a.isZero() and b.isZero()) return true;
        return a.value == b.value;
    }

    pub fn isZero(self: LogWeight) bool {
        return math.isInf(self.value);
    }

    pub fn compare(a: LogWeight, b: LogWeight) math.Order {
        return math.order(a.value, b.value);
    }

    pub fn reverse(self: LogWeight) LogWeight {
        return self;
    }

    pub fn hash(self: LogWeight) u64 {
        if (self.isZero()) return 0xFFFFFFFFFFFFFFFF;
        return @bitCast(self.value);
    }

    pub fn read(reader: anytype) !LogWeight {
        const v = try reader.readInt(u64, .little);
        return .{ .value = @bitCast(v) };
    }

    pub fn write(self: LogWeight, writer: anytype) !void {
        const bits: u64 = @bitCast(self.value);
        try writer.writeInt(u64, bits, .little);
    }

    pub fn format(self: LogWeight, w: anytype) !void {
        if (self.isZero()) {
            try w.writeAll("inf");
        } else {
            try w.print("{d}", .{self.value});
        }
    }
};

// ── Tests ──

test "tropical: zero and one" {
    const W = TropicalWeight;
    try std.testing.expect(W.one.eql(W.init(0.0)));
    try std.testing.expect(W.zero.isZero());
}

test "tropical: plus is min" {
    const W = TropicalWeight;
    const a = W.init(3.0);
    const b = W.init(5.0);
    try std.testing.expect(W.plus(a, b).eql(a));
    try std.testing.expect(W.plus(b, a).eql(a));
}

test "tropical: times is addition" {
    const W = TropicalWeight;
    const a = W.init(3.0);
    const b = W.init(5.0);
    try std.testing.expect(W.times(a, b).eql(W.init(8.0)));
}

test "tropical: zero annihilates" {
    const W = TropicalWeight;
    const a = W.init(3.0);
    try std.testing.expect(W.times(a, W.zero).isZero());
    try std.testing.expect(W.times(W.zero, a).isZero());
}

test "tropical: identity" {
    const W = TropicalWeight;
    const a = W.init(3.0);
    try std.testing.expect(W.plus(a, W.zero).eql(a));
    try std.testing.expect(W.times(a, W.one).eql(a));
}

test "log: zero and one" {
    const W = LogWeight;
    try std.testing.expect(W.one.eql(W.init(0.0)));
    try std.testing.expect(W.zero.isZero());
}

test "log: plus (log-add)" {
    const W = LogWeight;
    const a = W.init(1.0);
    const b = W.init(2.0);
    const result = W.plus(a, b);
    // -log(e^-1 + e^-2) ≈ 0.6867
    try std.testing.expectApproxEqAbs(result.value, 0.6867, 0.001);
}

test "log: times is addition" {
    const W = LogWeight;
    const a = W.init(1.0);
    const b = W.init(2.0);
    try std.testing.expect(W.times(a, b).eql(W.init(3.0)));
}

test "log: zero annihilates" {
    const W = LogWeight;
    const a = W.init(1.0);
    try std.testing.expect(W.times(a, W.zero).isZero());
}

test "log: identity" {
    const W = LogWeight;
    const a = W.init(1.0);
    try std.testing.expect(W.plus(a, W.zero).eql(a));
    try std.testing.expect(W.times(a, W.one).eql(a));
}

test "tropical: commutativity" {
    const W = TropicalWeight;
    const a = W.init(2.0);
    const b = W.init(7.0);
    try std.testing.expect(W.plus(a, b).eql(W.plus(b, a)));
    try std.testing.expect(W.times(a, b).eql(W.times(b, a)));
}

test "tropical: associativity" {
    const W = TropicalWeight;
    const a = W.init(2.0);
    const b = W.init(3.0);
    const c = W.init(5.0);
    try std.testing.expect(W.plus(W.plus(a, b), c).eql(W.plus(a, W.plus(b, c))));
    try std.testing.expect(W.times(W.times(a, b), c).eql(W.times(a, W.times(b, c))));
}
