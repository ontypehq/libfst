const std = @import("std");
const arc = @import("arc.zig");
const Label = arc.Label;
const Allocator = std.mem.Allocator;

/// Bidirectional mapping between symbols (strings) and labels (u32).
pub const SymbolTable = struct {
    allocator: Allocator,
    /// Label -> owned symbol string
    id_to_sym: std.ArrayListUnmanaged([]const u8),
    /// Symbol string -> Label
    sym_to_id: std.StringHashMapUnmanaged(Label),
    /// Next label to assign (starts at 1; 0 = epsilon reserved)
    next_label: Label,

    pub fn init(allocator: Allocator) SymbolTable {
        return .{
            .allocator = allocator,
            .id_to_sym = .empty,
            .sym_to_id = .empty,
            .next_label = 1,
        };
    }

    pub fn deinit(self: *SymbolTable) void {
        for (self.id_to_sym.items) |s| {
            self.allocator.free(s);
        }
        self.id_to_sym.deinit(self.allocator);
        self.sym_to_id.deinit(self.allocator);
    }

    /// Add a symbol with an auto-assigned label. Returns the label.
    pub fn addSymbol(self: *SymbolTable, symbol: []const u8) !Label {
        if (self.sym_to_id.get(symbol)) |existing| {
            return existing;
        }
        const label = self.next_label;
        const owned = try self.allocator.dupe(u8, symbol);
        errdefer self.allocator.free(owned);

        // Ensure id_to_sym has enough capacity (fill gaps with empty strings)
        while (self.id_to_sym.items.len <= label) {
            try self.id_to_sym.append(self.allocator, "");
        }
        // Put into sym_to_id BEFORE writing id_to_sym to avoid dangling pointer
        // on OOM: if put fails, errdefer frees owned and id_to_sym only has ""
        try self.sym_to_id.put(self.allocator, owned, label);
        self.id_to_sym.items[label] = owned;
        self.next_label += 1;
        return label;
    }

    /// Add a symbol with a specific label. Returns error if label is already used with a different symbol.
    pub fn addSymbolWithLabel(self: *SymbolTable, symbol: []const u8, label: Label) !void {
        if (self.sym_to_id.get(symbol)) |existing| {
            if (existing == label) return;
            return error.SymbolAlreadyExists;
        }

        const owned = try self.allocator.dupe(u8, symbol);
        errdefer self.allocator.free(owned);

        while (self.id_to_sym.items.len <= label) {
            try self.id_to_sym.append(self.allocator, "");
        }
        if (self.id_to_sym.items[label].len > 0) {
            return error.LabelAlreadyUsed;
        }
        // Put into sym_to_id BEFORE writing id_to_sym to avoid dangling pointer
        // on OOM: if put fails, errdefer frees owned and id_to_sym only has ""
        try self.sym_to_id.put(self.allocator, owned, label);
        self.id_to_sym.items[label] = owned;
        if (label >= self.next_label) {
            self.next_label = label + 1;
        }
    }

    /// Look up label by symbol name.
    pub fn findSymbol(self: *const SymbolTable, symbol: []const u8) ?Label {
        return self.sym_to_id.get(symbol);
    }

    /// Look up symbol name by label.
    pub fn findLabel(self: *const SymbolTable, label: Label) ?[]const u8 {
        if (label == 0) return "<eps>";
        if (label >= self.id_to_sym.items.len) return null;
        const s = self.id_to_sym.items[label];
        if (s.len == 0) return null;
        return s;
    }

    /// Number of symbols (excluding epsilon).
    pub fn numSymbols(self: *const SymbolTable) usize {
        return self.sym_to_id.count();
    }
};

// ── Tests ──

test "sym: add and lookup" {
    const allocator = std.testing.allocator;
    var syms = SymbolTable.init(allocator);
    defer syms.deinit();

    const a = try syms.addSymbol("hello");
    const b = try syms.addSymbol("world");
    const a2 = try syms.addSymbol("hello"); // duplicate

    try std.testing.expectEqual(a, a2);
    try std.testing.expect(a != b);
    try std.testing.expectEqualStrings("hello", syms.findLabel(a).?);
    try std.testing.expectEqualStrings("world", syms.findLabel(b).?);
    try std.testing.expectEqual(a, syms.findSymbol("hello").?);
    try std.testing.expectEqual(b, syms.findSymbol("world").?);
    try std.testing.expectEqual(@as(?Label, null), syms.findSymbol("missing"));
}

test "sym: epsilon label" {
    const allocator = std.testing.allocator;
    var syms = SymbolTable.init(allocator);
    defer syms.deinit();

    try std.testing.expectEqualStrings("<eps>", syms.findLabel(0).?);
}

test "sym: add with specific label" {
    const allocator = std.testing.allocator;
    var syms = SymbolTable.init(allocator);
    defer syms.deinit();

    try syms.addSymbolWithLabel("a", 5);
    try syms.addSymbolWithLabel("b", 10);

    try std.testing.expectEqualStrings("a", syms.findLabel(5).?);
    try std.testing.expectEqualStrings("b", syms.findLabel(10).?);
    try std.testing.expectEqual(@as(Label, 5), syms.findSymbol("a").?);
}

test "sym: numSymbols" {
    const allocator = std.testing.allocator;
    var syms = SymbolTable.init(allocator);
    defer syms.deinit();

    try std.testing.expectEqual(@as(usize, 0), syms.numSymbols());
    _ = try syms.addSymbol("a");
    try std.testing.expectEqual(@as(usize, 1), syms.numSymbols());
    _ = try syms.addSymbol("b");
    try std.testing.expectEqual(@as(usize, 2), syms.numSymbols());
    _ = try syms.addSymbol("a"); // duplicate
    try std.testing.expectEqual(@as(usize, 2), syms.numSymbols());
}
