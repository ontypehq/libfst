const std = @import("std");
const weight_mod = @import("weight.zig");
const arc_mod = @import("arc.zig");
const mutable_fst_mod = @import("mutable-fst.zig");
const fst_mod = @import("fst.zig");
const string_mod = @import("string.zig");
const io_text = @import("io/text.zig");
const io_binary = @import("io/binary.zig");
const compose_mod = @import("ops/compose.zig");
const determinize_mod = @import("ops/determinize.zig");
const minimize_mod = @import("ops/minimize.zig");
const rm_epsilon_mod = @import("ops/rm-epsilon.zig");
const shortest_path_mod = @import("ops/shortest-path.zig");
const union_mod = @import("ops/union.zig");
const concat_mod = @import("ops/concat.zig");
const closure_mod = @import("ops/closure.zig");
const invert_mod = @import("ops/invert.zig");
const optimize_mod = @import("ops/optimize.zig");
const rewrite_mod = @import("ops/rewrite.zig");
const difference_mod = @import("ops/difference.zig");
const replace_mod = @import("ops/replace.zig");
const project_mod = @import("ops/project.zig");

const W = weight_mod.TropicalWeight;
const A = arc_mod.Arc(W);
const StateId = arc_mod.StateId;
const Label = arc_mod.Label;
const no_state = arc_mod.no_state;

const alloc = std.heap.c_allocator;

// ── Handle table ──
// Prevents double-free, use-after-free, and type confusion at the C boundary.
// C consumers receive opaque u32 handles, never raw pointers.

const invalid_handle: u32 = std.math.maxInt(u32);

fn HandleTable(comptime T: type) type {
    return struct {
        slots: std.ArrayListUnmanaged(?*T) = .{},
        free_list: std.ArrayListUnmanaged(u32) = .{},

        const Self = @This();

        /// Insert a new object. Caller MUST hold `api_mutex`.
        fn insert(self: *Self, ptr: *T) u32 {
            if (self.free_list.items.len > 0) {
                const idx = self.free_list.pop().?;
                self.slots.items[idx] = ptr;
                return idx;
            }
            self.slots.append(alloc, ptr) catch return invalid_handle;
            return @intCast(self.slots.items.len - 1);
        }

        /// Caller MUST hold `api_mutex`.
        fn get(self: *Self, handle: u32) ?*T {
            if (handle >= self.slots.items.len) return null;
            return self.slots.items[handle];
        }

        /// Caller MUST hold `api_mutex`.
        fn getConst(self: *Self, handle: u32) ?*const T {
            if (handle >= self.slots.items.len) return null;
            return self.slots.items[handle];
        }

        /// Remove and destroy the object. Caller MUST hold `api_mutex`.
        fn remove(self: *Self, handle: u32, deinit_fn: *const fn (*T) void) bool {
            if (handle >= self.slots.items.len) return false;
            const ptr = self.slots.items[handle] orelse return false;
            deinit_fn(ptr);
            alloc.destroy(ptr);
            self.slots.items[handle] = null;
            self.free_list.append(alloc, handle) catch {};
            return true;
        }
    };
}

const MutableFst = mutable_fst_mod.MutableFst(W);
const Fst = fst_mod.Fst(W);

var mutable_table: HandleTable(MutableFst) = .{};
var fst_table: HandleTable(Fst) = .{};

/// Single global mutex protecting ALL handle table access and the pointed-to
/// objects. Every C API entry point locks this for its entire duration, so
/// pointers obtained from get()/getConst() remain valid until the export
/// function returns and unlocks.
var api_mutex: std.Thread.Mutex = .{};

fn mutableDeinit(ptr: *MutableFst) void {
    ptr.deinit();
}

fn fstDeinit(ptr: *Fst) void {
    ptr.deinit();
}

/// Release all global handle tables. Call once at program shutdown.
/// After this, all handles are invalidated.
/// Thread safety: caller must ensure no other C API calls are in flight.
export fn fst_teardown() callconv(.c) void {
    api_mutex.lock();
    defer api_mutex.unlock();
    // Free all remaining mutable FSTs
    for (mutable_table.slots.items) |slot| {
        if (slot) |ptr| {
            var tmp = ptr.*;
            tmp.deinit();
            alloc.destroy(ptr);
        }
    }
    mutable_table.slots.deinit(alloc);
    mutable_table.free_list.deinit(alloc);
    mutable_table = .{};

    // Free all remaining frozen FSTs
    for (fst_table.slots.items) |slot| {
        if (slot) |ptr| {
            var tmp = ptr.*;
            tmp.deinit();
            alloc.destroy(ptr);
        }
    }
    fst_table.slots.deinit(alloc);
    fst_table.free_list.deinit(alloc);
    fst_table = .{};
}

// Helpers to create and register objects

fn newMutableHandle(fst: MutableFst) u32 {
    const ptr = alloc.create(MutableFst) catch return invalid_handle;
    ptr.* = fst;
    const h = mutable_table.insert(ptr);
    if (h == invalid_handle) {
        var tmp = ptr.*;
        tmp.deinit();
        alloc.destroy(ptr);
    }
    return h;
}

fn newFstHandle(fst: Fst) u32 {
    const ptr = alloc.create(Fst) catch return invalid_handle;
    ptr.* = fst;
    const h = fst_table.insert(ptr);
    if (h == invalid_handle) {
        var tmp = ptr.*;
        tmp.deinit();
        alloc.destroy(ptr);
    }
    return h;
}

// ── Error codes ──

pub const FstError = enum(c_int) {
    ok = 0,
    oom = 1,
    invalid_arg = 2,
    invalid_state = 3,
    io_error = 4,
};

// ── C-compatible arc ──

pub const CFstArc = extern struct {
    ilabel: u32,
    olabel: u32,
    weight: f64,
    nextstate: u32,
};

// ── MutableFst lifecycle ──

export fn fst_mutable_new() callconv(.c) u32 {
    api_mutex.lock();
    defer api_mutex.unlock();
    return newMutableHandle(MutableFst.init(alloc));
}

export fn fst_mutable_free(handle: u32) callconv(.c) void {
    api_mutex.lock();
    defer api_mutex.unlock();
    _ = mutable_table.remove(handle, &mutableDeinit);
}

export fn fst_mutable_add_state(handle: u32) callconv(.c) u32 {
    api_mutex.lock();
    defer api_mutex.unlock();
    const h = mutable_table.get(handle) orelse return no_state;
    return h.addState() catch return no_state;
}

export fn fst_mutable_set_start(handle: u32, state: u32) callconv(.c) FstError {
    api_mutex.lock();
    defer api_mutex.unlock();
    const h = mutable_table.get(handle) orelse return .invalid_arg;
    if (state >= h.numStates()) return .invalid_state;
    h.setStart(state);
    return .ok;
}

export fn fst_mutable_set_final(handle: u32, state: u32, weight: f64) callconv(.c) FstError {
    api_mutex.lock();
    defer api_mutex.unlock();
    const h = mutable_table.get(handle) orelse return .invalid_arg;
    if (state >= h.numStates()) return .invalid_state;
    h.setFinal(state, W.init(weight));
    return .ok;
}

export fn fst_mutable_add_arc(handle: u32, src: u32, ilabel: u32, olabel: u32, weight: f64, nextstate: u32) callconv(.c) FstError {
    api_mutex.lock();
    defer api_mutex.unlock();
    const h = mutable_table.get(handle) orelse return .invalid_arg;
    if (src >= h.numStates()) return .invalid_state;
    if (nextstate >= h.numStates()) return .invalid_state;
    h.addArc(src, A.init(ilabel, olabel, W.init(weight), nextstate)) catch return .oom;
    return .ok;
}

// ── Freeze ──

export fn fst_freeze(mutable_handle: u32) callconv(.c) u32 {
    api_mutex.lock();
    defer api_mutex.unlock();
    const mh = mutable_table.get(mutable_handle) orelse return invalid_handle;
    var frozen = Fst.fromMutable(alloc, mh) catch return invalid_handle;
    const h = newFstHandle(frozen);
    if (h == invalid_handle) {
        frozen.deinit();
    }
    return h;
}

// ── Fst (immutable) lifecycle ──

export fn fst_free(handle: u32) callconv(.c) void {
    api_mutex.lock();
    defer api_mutex.unlock();
    _ = fst_table.remove(handle, &fstDeinit);
}

export fn fst_start(handle: u32) callconv(.c) u32 {
    api_mutex.lock();
    defer api_mutex.unlock();
    const h = fst_table.getConst(handle) orelse return no_state;
    return h.start();
}

export fn fst_num_states(handle: u32) callconv(.c) u32 {
    api_mutex.lock();
    defer api_mutex.unlock();
    const h = fst_table.getConst(handle) orelse return 0;
    return h.numStates();
}

export fn fst_num_arcs(handle: u32, state: u32) callconv(.c) u32 {
    api_mutex.lock();
    defer api_mutex.unlock();
    const h = fst_table.getConst(handle) orelse return 0;
    if (state >= h.numStates()) return 0;
    return h.numArcs(state);
}

export fn fst_final_weight(handle: u32, state: u32) callconv(.c) f64 {
    api_mutex.lock();
    defer api_mutex.unlock();
    const h = fst_table.getConst(handle) orelse return std.math.inf(f64);
    if (state >= h.numStates()) return std.math.inf(f64);
    return h.finalWeight(state).value;
}

export fn fst_get_arcs(handle: u32, state: u32, buf: ?[*]CFstArc, buf_len: u32) callconv(.c) u32 {
    api_mutex.lock();
    defer api_mutex.unlock();
    const h = fst_table.getConst(handle) orelse return 0;
    if (state >= h.numStates()) return 0;
    const arcs = h.arcs(state);
    const count = @min(@as(u32, @intCast(arcs.len)), buf_len);
    if (buf) |b| {
        for (0..count) |i| {
            b[i] = .{
                .ilabel = arcs[i].ilabel,
                .olabel = arcs[i].olabel,
                .weight = arcs[i].weight,
                .nextstate = arcs[i].nextstate,
            };
        }
    }
    return count;
}

// ── I/O ──

export fn fst_read_text(path: ?[*:0]const u8) callconv(.c) u32 {
    api_mutex.lock();
    defer api_mutex.unlock();
    const p = path orelse return invalid_handle;
    const file = std.fs.cwd().openFileZ(p, .{}) catch return invalid_handle;
    defer file.close();

    const content = file.readToEndAlloc(alloc, 64 * 1024 * 1024) catch return invalid_handle;
    defer alloc.free(content);

    var fst = io_text.readText(W, alloc, content) catch return invalid_handle;
    const h = newMutableHandle(fst);
    if (h == invalid_handle) fst.deinit();
    return h;
}

export fn fst_load(path: ?[*:0]const u8) callconv(.c) u32 {
    api_mutex.lock();
    defer api_mutex.unlock();
    const p = path orelse return invalid_handle;
    var fst = io_binary.readBinary(W, alloc, std.mem.span(p)) catch return invalid_handle;
    const h = newFstHandle(fst);
    if (h == invalid_handle) fst.deinit();
    return h;
}

export fn fst_save(handle: u32, path: ?[*:0]const u8) callconv(.c) FstError {
    api_mutex.lock();
    defer api_mutex.unlock();
    const h = fst_table.getConst(handle) orelse return .invalid_arg;
    const p = path orelse return .invalid_arg;
    io_binary.writeBinary(W, h, std.mem.span(p)) catch return .io_error;
    return .ok;
}

// ── Operations ──

export fn fst_compose(a_handle: u32, b_handle: u32) callconv(.c) u32 {
    api_mutex.lock();
    defer api_mutex.unlock();
    const ha = mutable_table.getConst(a_handle) orelse return invalid_handle;
    const hb = mutable_table.getConst(b_handle) orelse return invalid_handle;
    var result = compose_mod.compose(W, alloc, ha, hb) catch return invalid_handle;
    const h = newMutableHandle(result);
    if (h == invalid_handle) result.deinit();
    return h;
}

export fn fst_determinize(handle: u32) callconv(.c) u32 {
    api_mutex.lock();
    defer api_mutex.unlock();
    const h = mutable_table.getConst(handle) orelse return invalid_handle;
    var result = determinize_mod.determinize(W, alloc, h) catch return invalid_handle;
    const rh = newMutableHandle(result);
    if (rh == invalid_handle) result.deinit();
    return rh;
}

export fn fst_minimize(handle: u32) callconv(.c) FstError {
    api_mutex.lock();
    defer api_mutex.unlock();
    const h = mutable_table.get(handle) orelse return .invalid_arg;
    minimize_mod.minimize(W, alloc, h) catch return .oom;
    return .ok;
}

export fn fst_rm_epsilon(handle: u32) callconv(.c) u32 {
    api_mutex.lock();
    defer api_mutex.unlock();
    const h = mutable_table.getConst(handle) orelse return invalid_handle;
    var result = rm_epsilon_mod.rmEpsilon(W, alloc, h) catch return invalid_handle;
    const rh = newMutableHandle(result);
    if (rh == invalid_handle) result.deinit();
    return rh;
}

export fn fst_shortest_path(handle: u32, n: u32) callconv(.c) u32 {
    api_mutex.lock();
    defer api_mutex.unlock();
    const h = mutable_table.getConst(handle) orelse return invalid_handle;
    var result = shortest_path_mod.shortestPath(W, alloc, h, n) catch return invalid_handle;
    const rh = newMutableHandle(result);
    if (rh == invalid_handle) result.deinit();
    return rh;
}

export fn fst_union(a_handle: u32, b_handle: u32) callconv(.c) FstError {
    api_mutex.lock();
    defer api_mutex.unlock();
    const ha = mutable_table.get(a_handle) orelse return .invalid_arg;
    const hb = mutable_table.getConst(b_handle) orelse return .invalid_arg;
    union_mod.union_(W, ha, hb) catch return .oom;
    return .ok;
}

export fn fst_concat(a_handle: u32, b_handle: u32) callconv(.c) FstError {
    api_mutex.lock();
    defer api_mutex.unlock();
    const ha = mutable_table.get(a_handle) orelse return .invalid_arg;
    const hb = mutable_table.getConst(b_handle) orelse return .invalid_arg;
    concat_mod.concat(W, ha, hb) catch return .oom;
    return .ok;
}

export fn fst_closure(handle: u32, closure_type: c_int) callconv(.c) FstError {
    api_mutex.lock();
    defer api_mutex.unlock();
    const h = mutable_table.get(handle) orelse return .invalid_arg;
    const ct: closure_mod.ClosureType = switch (closure_type) {
        0 => .star,
        1 => .plus,
        2 => .ques,
        else => return .invalid_arg,
    };
    closure_mod.closure(W, h, ct) catch return .oom;
    return .ok;
}

export fn fst_invert(handle: u32) callconv(.c) void {
    api_mutex.lock();
    defer api_mutex.unlock();
    if (mutable_table.get(handle)) |h| {
        invert_mod.invert(W, h);
    }
}

export fn fst_optimize(handle: u32) callconv(.c) u32 {
    api_mutex.lock();
    defer api_mutex.unlock();
    const h = mutable_table.getConst(handle) orelse return invalid_handle;
    var result = optimize_mod.optimize(W, alloc, h) catch return invalid_handle;
    const rh = newMutableHandle(result);
    if (rh == invalid_handle) result.deinit();
    return rh;
}

export fn fst_cdrewrite(tau_h: u32, lambda_h: u32, rho_h: u32, sigma_h: u32) callconv(.c) u32 {
    api_mutex.lock();
    defer api_mutex.unlock();
    const t = mutable_table.getConst(tau_h) orelse return invalid_handle;
    const l = mutable_table.getConst(lambda_h) orelse return invalid_handle;
    const r = mutable_table.getConst(rho_h) orelse return invalid_handle;
    const s = mutable_table.getConst(sigma_h) orelse return invalid_handle;
    var result = rewrite_mod.cdrewrite(W, alloc, t, l, r, s) catch return invalid_handle;
    const rh = newMutableHandle(result);
    if (rh == invalid_handle) result.deinit();
    return rh;
}

export fn fst_difference(a_handle: u32, b_handle: u32) callconv(.c) u32 {
    api_mutex.lock();
    defer api_mutex.unlock();
    const ha = mutable_table.getConst(a_handle) orelse return invalid_handle;
    const hb = mutable_table.getConst(b_handle) orelse return invalid_handle;
    var result = difference_mod.difference(W, alloc, ha, hb) catch return invalid_handle;
    const h = newMutableHandle(result);
    if (h == invalid_handle) result.deinit();
    return h;
}

export fn fst_replace(root_handle: u32, labels: ?[*]const u32, fst_handles: ?[*]const u32, num_pairs: u32) callconv(.c) u32 {
    api_mutex.lock();
    defer api_mutex.unlock();
    const root = mutable_table.getConst(root_handle) orelse return invalid_handle;
    const lbl_ptr = labels orelse return invalid_handle;
    const fst_ptr = fst_handles orelse return invalid_handle;

    // Build pairs array on the stack (arena for larger)
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const pairs = arena.alloc(replace_mod.ReplacePair(W), num_pairs) catch return invalid_handle;
    for (0..num_pairs) |i| {
        const fst_h = mutable_table.getConst(fst_ptr[i]) orelse return invalid_handle;
        pairs[i] = .{ .label = lbl_ptr[i], .fst = fst_h };
    }

    var result = replace_mod.replace(W, alloc, root, pairs) catch return invalid_handle;
    const h = newMutableHandle(result);
    if (h == invalid_handle) result.deinit();
    return h;
}

export fn fst_project(handle: u32, side: c_int) callconv(.c) void {
    api_mutex.lock();
    defer api_mutex.unlock();
    const h = mutable_table.get(handle) orelse return;
    const pt: project_mod.ProjectType = switch (side) {
        0 => .input,
        1 => .output,
        else => return,
    };
    project_mod.project(W, h, pt);
}

// ── String utilities ──

export fn fst_compile_string(input: ?[*]const u8, len: u32) callconv(.c) u32 {
    api_mutex.lock();
    defer api_mutex.unlock();
    const i = input orelse return invalid_handle;
    var fst = string_mod.compileString(W, alloc, i[0..len]) catch return invalid_handle;
    const h = newMutableHandle(fst);
    if (h == invalid_handle) fst.deinit();
    return h;
}

export fn fst_print_string(handle: u32, buf: ?[*]u8, buf_len: u32) callconv(.c) i32 {
    api_mutex.lock();
    defer api_mutex.unlock();
    const h = mutable_table.getConst(handle) orelse return -1;
    const result = string_mod.printString(W, alloc, h) catch return -1;
    const s = result orelse return -1;
    defer alloc.free(s);

    if (s.len > buf_len) return -1;
    if (buf) |b| {
        @memcpy(b[0..s.len], s);
    }
    return @intCast(s.len);
}

// ── Mutable query (for C consumers) ──

export fn fst_mutable_start(handle: u32) callconv(.c) u32 {
    api_mutex.lock();
    defer api_mutex.unlock();
    const h = mutable_table.getConst(handle) orelse return no_state;
    return h.start();
}

export fn fst_mutable_num_states(handle: u32) callconv(.c) u32 {
    api_mutex.lock();
    defer api_mutex.unlock();
    const h = mutable_table.getConst(handle) orelse return 0;
    return @intCast(h.numStates());
}

export fn fst_mutable_num_arcs(handle: u32, state: u32) callconv(.c) u32 {
    api_mutex.lock();
    defer api_mutex.unlock();
    const h = mutable_table.getConst(handle) orelse return 0;
    if (state >= h.numStates()) return 0;
    return @intCast(h.numArcs(state));
}

export fn fst_mutable_final_weight(handle: u32, state: u32) callconv(.c) f64 {
    api_mutex.lock();
    defer api_mutex.unlock();
    const h = mutable_table.getConst(handle) orelse return std.math.inf(f64);
    if (state >= h.numStates()) return std.math.inf(f64);
    return h.finalWeight(state).value;
}

export fn fst_mutable_get_arcs(handle: u32, state: u32, buf: ?[*]CFstArc, buf_len: u32) callconv(.c) u32 {
    api_mutex.lock();
    defer api_mutex.unlock();
    const h = mutable_table.getConst(handle) orelse return 0;
    if (state >= h.numStates()) return 0;
    const arcs = h.arcs(state);
    const count = @min(@as(u32, @intCast(arcs.len)), buf_len);
    if (buf) |b| {
        for (0..count) |i| {
            b[i] = .{
                .ilabel = arcs[i].ilabel,
                .olabel = arcs[i].olabel,
                .weight = arcs[i].weight.value,
                .nextstate = arcs[i].nextstate,
            };
        }
    }
    return count;
}
