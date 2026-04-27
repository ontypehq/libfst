const std = @import("std");
const weight_mod = @import("weight.zig");
const arc_mod = @import("arc.zig");
const mutable_fst_mod = @import("mutable-fst.zig");
const fst_mod = @import("fst.zig");
const string_mod = @import("string.zig");
const io_text = @import("io/text.zig");
const io_binary = @import("io/binary.zig");
const compose_mod = @import("ops/compose.zig");
const compose_shortest_path_mod = @import("ops/compose-shortest-path.zig");
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

fn defaultIo() std.Io {
    // C ABI entry points do not receive Zig's `std.process.Init`; keep the
    // 0.16 fallback I/O choice centralized instead of leaking it across calls.
    return std.Io.Threaded.global_single_threaded.io();
}

fn traceNowNs() i128 {
    return @intCast(std.Io.Clock.now(.awake, defaultIo()).toNanoseconds());
}

const ApiMutex = struct {
    inner: std.Io.Mutex = .init,

    fn lock(self: *ApiMutex) void {
        self.inner.lockUncancelable(defaultIo());
    }

    fn unlock(self: *ApiMutex) void {
        self.inner.unlock(defaultIo());
    }
};

var compose_trace_checked: bool = false;
var compose_trace_enabled: bool = false;

fn isComposeTraceEnabled() bool {
    if (!compose_trace_checked) {
        compose_trace_checked = true;
        compose_trace_enabled = std.c.getenv("LIBFST_TRACE_COMPOSE") != null;
    }
    return compose_trace_enabled;
}

fn mutableTotalArcs(fst: *const MutableFst) usize {
    var total: usize = 0;
    for (0..fst.numStates()) |i| {
        total += fst.numArcs(@intCast(i));
    }
    return total;
}

fn traceComposeFrozen(
    tag: []const u8,
    a_handle: Handle,
    b_handle: Handle,
    in_states: usize,
    in_arcs: usize,
    out_states: usize,
    out_arcs: usize,
    elapsed_ns: i128,
) void {
    if (!isComposeTraceEnabled()) return;

    var err_buf: [512]u8 = undefined;
    var err_writer = std.Io.File.stderr().writer(defaultIo(), &err_buf);
    const err = &err_writer.interface;
    err.print(
        "[libfst] {s} op=fst_compose_frozen a={d} b={d} in_states={d} in_arcs={d} out_states={d} out_arcs={d} elapsed_us={d}\n",
        .{
            tag,
            a_handle,
            b_handle,
            in_states,
            in_arcs,
            out_states,
            out_arcs,
            @divTrunc(elapsed_ns, std.time.ns_per_us),
        },
    ) catch {};
    err.flush() catch {};
}

// ── Handle table ──
// Prevents double-free, stale-handle reuse, and type confusion at the C boundary.
// C consumers receive opaque u64 handles, never raw pointers.

const Handle = u64;
const SlotIndex = u32;
const invalid_handle: Handle = std.math.maxInt(Handle);
const invalid_slot: SlotIndex = std.math.maxInt(SlotIndex);

const DecodedHandle = struct {
    index: SlotIndex,
    generation: u32,
};

fn encodeHandle(index: SlotIndex, generation: u32) Handle {
    return (@as(Handle, generation) << 32) | @as(Handle, index);
}

fn decodeHandle(handle: Handle) ?DecodedHandle {
    if (handle == invalid_handle) return null;
    const generation: u32 = @intCast(handle >> 32);
    if (generation == 0) return null;
    const index: SlotIndex = @intCast(handle & std.math.maxInt(u32));
    if (index == invalid_slot) return null;
    return .{ .index = index, .generation = generation };
}

fn HandleTable(comptime T: type) type {
    return struct {
        slots: std.ArrayList(?*T) = .empty,
        free_list: std.ArrayList(SlotIndex) = .empty,
        generations: std.ArrayList(u32) = .empty,
        versions: std.ArrayList(u64) = .empty,
        pin_counts: std.ArrayList(u32) = .empty,
        pending_free: std.ArrayList(bool) = .empty,

        const Self = @This();

        /// Insert a new object. Caller MUST hold `api_mutex`.
        fn insert(self: *Self, ptr: *T) Handle {
            if (self.free_list.items.len > 0) {
                const idx = self.free_list.pop().?;
                self.generations.items[idx] +%= 1;
                if (self.generations.items[idx] == 0) self.generations.items[idx] = 1;
                self.slots.items[idx] = ptr;
                self.versions.items[idx] = 0;
                self.pin_counts.items[idx] = 0;
                self.pending_free.items[idx] = false;
                return encodeHandle(idx, self.generations.items[idx]);
            }
            self.slots.append(alloc, ptr) catch return invalid_handle;
            self.generations.append(alloc, 1) catch {
                _ = self.slots.pop();
                return invalid_handle;
            };
            self.versions.append(alloc, 0) catch {
                _ = self.generations.pop();
                _ = self.slots.pop();
                return invalid_handle;
            };
            self.pin_counts.append(alloc, 0) catch {
                _ = self.versions.pop();
                _ = self.generations.pop();
                _ = self.slots.pop();
                return invalid_handle;
            };
            self.pending_free.append(alloc, false) catch {
                _ = self.pin_counts.pop();
                _ = self.versions.pop();
                _ = self.generations.pop();
                _ = self.slots.pop();
                return invalid_handle;
            };
            const idx: SlotIndex = @intCast(self.slots.items.len - 1);
            return encodeHandle(idx, 1);
        }

        /// Caller MUST hold `api_mutex`.
        fn get(self: *Self, handle: Handle) ?*T {
            const decoded = self.validate(handle) orelse return null;
            return self.slots.items[decoded.index];
        }

        /// Caller MUST hold `api_mutex`.
        fn getConst(self: *Self, handle: Handle) ?*const T {
            const decoded = self.validate(handle) orelse return null;
            return self.slots.items[decoded.index];
        }

        /// Caller MUST hold `api_mutex`.
        fn generation(self: *Self, handle: Handle) ?u64 {
            const decoded = self.validate(handle) orelse return null;
            return self.versions.items[decoded.index];
        }

        /// Caller MUST hold `api_mutex`.
        fn bumpGeneration(self: *Self, handle: Handle) bool {
            const decoded = self.validate(handle) orelse return false;
            self.versions.items[decoded.index] +%= 1;
            return true;
        }

        /// Pin a handle for lock-free read access.
        /// While pinned, remove() defers destruction until unpin().
        /// Caller MUST hold `api_mutex`.
        fn pinConst(self: *Self, handle: Handle) ?*const T {
            const decoded = self.validate(handle) orelse return null;
            const ptr = self.slots.items[decoded.index] orelse return null;
            self.pin_counts.items[decoded.index] +%= 1;
            if (self.pin_counts.items[decoded.index] == 0) self.pin_counts.items[decoded.index] = 1;
            return ptr;
        }

        /// Release a previously pinned handle.
        /// Caller MUST hold `api_mutex`.
        fn unpin(self: *Self, handle: Handle, deinit_fn: *const fn (*T) void) bool {
            const decoded = decodeHandle(handle) orelse return false;
            if (decoded.index >= self.slots.items.len) return false;
            if (self.pin_counts.items[decoded.index] == 0) return false;
            self.pin_counts.items[decoded.index] -= 1;
            if (self.pin_counts.items[decoded.index] != 0) return true;
            if (!self.pending_free.items[decoded.index]) return true;

            const ptr = self.slots.items[decoded.index] orelse {
                self.pending_free.items[decoded.index] = false;
                return false;
            };
            deinit_fn(ptr);
            alloc.destroy(ptr);
            self.slots.items[decoded.index] = null;
            self.pending_free.items[decoded.index] = false;
            self.free_list.append(alloc, decoded.index) catch {};
            return true;
        }

        /// Remove and destroy the object. Caller MUST hold `api_mutex`.
        fn remove(self: *Self, handle: Handle, deinit_fn: *const fn (*T) void) bool {
            const decoded = self.validate(handle) orelse return false;
            const ptr = self.slots.items[decoded.index] orelse return false;
            if (self.pin_counts.items[decoded.index] > 0) {
                self.pending_free.items[decoded.index] = true;
                self.invalidateSlot(decoded.index);
                return true;
            }
            deinit_fn(ptr);
            alloc.destroy(ptr);
            self.slots.items[decoded.index] = null;
            self.invalidateSlot(decoded.index);
            self.free_list.append(alloc, decoded.index) catch {};
            return true;
        }

        fn validate(self: *Self, handle: Handle) ?DecodedHandle {
            const decoded = decodeHandle(handle) orelse return null;
            if (decoded.index >= self.slots.items.len) return null;
            if (self.pending_free.items[decoded.index]) return null;
            if (self.generations.items[decoded.index] != decoded.generation) return null;
            return decoded;
        }

        fn invalidateSlot(self: *Self, index: SlotIndex) void {
            self.generations.items[index] +%= 1;
            if (self.generations.items[index] == 0) self.generations.items[index] = 1;
            self.versions.items[index] +%= 1;
        }
    };
}

const MutableFst = mutable_fst_mod.MutableFst(W);
const Fst = fst_mod.Fst(W);

var mutable_table: HandleTable(MutableFst) = .{};
var fst_table: HandleTable(Fst) = .{};

/// Global mutex protects handle tables and short critical sections.
/// Heavy algorithms run outside this lock using mutable snapshots and
/// optionally pinned immutable handles.
var api_mutex: ApiMutex = .{};

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
    mutable_table.generations.deinit(alloc);
    mutable_table.versions.deinit(alloc);
    mutable_table.pin_counts.deinit(alloc);
    mutable_table.pending_free.deinit(alloc);
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
    fst_table.generations.deinit(alloc);
    fst_table.versions.deinit(alloc);
    fst_table.pin_counts.deinit(alloc);
    fst_table.pending_free.deinit(alloc);
    fst_table = .{};
}

// Helpers to create and register objects

fn newMutableHandle(fst: MutableFst) Handle {
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

fn newFstHandle(fst: Fst) Handle {
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

fn cloneFstOwned(src: *const Fst) !Fst {
    const bytes = try alloc.alignedAlloc(u8, .@"8", src.bytes.len);
    errdefer alloc.free(bytes);
    @memcpy(bytes, src.bytes);
    var cloned = try Fst.fromBytes(bytes);
    cloned.source = .owned;
    cloned.allocator = alloc;
    return cloned;
}

fn cloneMutableOwned(src: *const MutableFst) !MutableFst {
    return src.clone(alloc);
}

fn resolveExecutableFromPath(name: []const u8) ![]u8 {
    if (std.mem.findScalar(u8, name, '/') != null) {
        return try alloc.dupe(u8, name);
    }

    const path_z = std.c.getenv("PATH") orelse return try alloc.dupe(u8, name);
    var dirs = std.mem.splitScalar(u8, std.mem.span(path_z), ':');
    while (dirs.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, name });
        std.Io.Dir.cwd().access(defaultIo(), candidate, .{ .execute = true }) catch {
            alloc.free(candidate);
            continue;
        };
        return candidate;
    }

    return try alloc.dupe(u8, name);
}

fn loadOpenFstViaFstPrint(path: []const u8) !Fst {
    const fstprint = try resolveExecutableFromPath("fstprint");
    defer alloc.free(fstprint);

    const argv = [_][]const u8{ fstprint, path };
    const result = try std.process.run(alloc, defaultIo(), .{
        .argv = &argv,
        .stdout_limit = .limited(512 * 1024 * 1024),
        .stderr_limit = .limited(512 * 1024 * 1024),
    });
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    switch (result.term) {
        .exited => |code| {
            if (code != 0) return error.ExternalToolFailed;
        },
        else => return error.ExternalToolFailed,
    }

    var mutable = try io_text.readText(W, alloc, result.stdout);
    defer mutable.deinit();
    return try Fst.fromMutable(alloc, &mutable);
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

export fn fst_mutable_new() callconv(.c) Handle {
    api_mutex.lock();
    defer api_mutex.unlock();
    return newMutableHandle(MutableFst.init(alloc));
}

export fn fst_mutable_clone(handle: Handle) callconv(.c) Handle {
    api_mutex.lock();
    const h = mutable_table.getConst(handle) orelse {
        api_mutex.unlock();
        return invalid_handle;
    };
    var cloned = cloneMutableOwned(h) catch {
        api_mutex.unlock();
        return invalid_handle;
    };
    api_mutex.unlock();

    api_mutex.lock();
    const rh = newMutableHandle(cloned);
    api_mutex.unlock();
    if (rh == invalid_handle) {
        cloned.deinit();
    }
    return rh;
}

export fn fst_mutable_free(handle: Handle) callconv(.c) void {
    api_mutex.lock();
    defer api_mutex.unlock();
    _ = mutable_table.remove(handle, &mutableDeinit);
}

export fn fst_mutable_add_state(handle: Handle) callconv(.c) u32 {
    api_mutex.lock();
    defer api_mutex.unlock();
    const h = mutable_table.get(handle) orelse return no_state;
    return h.addState() catch return no_state;
}

export fn fst_mutable_set_start(handle: Handle, state: u32) callconv(.c) FstError {
    api_mutex.lock();
    defer api_mutex.unlock();
    const h = mutable_table.get(handle) orelse return .invalid_arg;
    if (state >= h.numStates()) return .invalid_state;
    h.setStart(state);
    return .ok;
}

export fn fst_mutable_set_final(handle: Handle, state: u32, weight: f64) callconv(.c) FstError {
    api_mutex.lock();
    defer api_mutex.unlock();
    const h = mutable_table.get(handle) orelse return .invalid_arg;
    if (state >= h.numStates()) return .invalid_state;
    h.setFinal(state, W.init(weight));
    return .ok;
}

export fn fst_mutable_add_arc(handle: Handle, src: u32, ilabel: u32, olabel: u32, weight: f64, nextstate: u32) callconv(.c) FstError {
    api_mutex.lock();
    defer api_mutex.unlock();
    const h = mutable_table.get(handle) orelse return .invalid_arg;
    if (src >= h.numStates()) return .invalid_state;
    if (nextstate >= h.numStates()) return .invalid_state;
    h.addArc(src, A.init(ilabel, olabel, W.init(weight), nextstate)) catch return .oom;
    return .ok;
}

// ── Freeze ──

export fn fst_freeze(mutable_handle: Handle) callconv(.c) Handle {
    api_mutex.lock();
    const mh = mutable_table.getConst(mutable_handle) orelse {
        api_mutex.unlock();
        return invalid_handle;
    };
    var snapshot = mh.clone(alloc) catch {
        api_mutex.unlock();
        return invalid_handle;
    };
    api_mutex.unlock();
    defer snapshot.deinit();

    var frozen = Fst.fromMutable(alloc, &snapshot) catch return invalid_handle;
    api_mutex.lock();
    const h = newFstHandle(frozen);
    api_mutex.unlock();
    if (h == invalid_handle) frozen.deinit();
    return h;
}

// ── Fst (immutable) lifecycle ──

export fn fst_free(handle: Handle) callconv(.c) void {
    api_mutex.lock();
    defer api_mutex.unlock();
    _ = fst_table.remove(handle, &fstDeinit);
}

export fn fst_start(handle: Handle) callconv(.c) u32 {
    api_mutex.lock();
    defer api_mutex.unlock();
    const h = fst_table.getConst(handle) orelse return no_state;
    return h.start();
}

export fn fst_num_states(handle: Handle) callconv(.c) u32 {
    api_mutex.lock();
    defer api_mutex.unlock();
    const h = fst_table.getConst(handle) orelse return 0;
    return h.numStates();
}

export fn fst_num_arcs(handle: Handle, state: u32) callconv(.c) u32 {
    api_mutex.lock();
    defer api_mutex.unlock();
    const h = fst_table.getConst(handle) orelse return 0;
    if (state >= h.numStates()) return 0;
    return h.numArcs(state);
}

export fn fst_final_weight(handle: Handle, state: u32) callconv(.c) f64 {
    api_mutex.lock();
    defer api_mutex.unlock();
    const h = fst_table.getConst(handle) orelse return std.math.inf(f64);
    if (state >= h.numStates()) return std.math.inf(f64);
    return h.finalWeight(state).value;
}

export fn fst_get_arcs(handle: Handle, state: u32, buf: ?[*]CFstArc, buf_len: u32) callconv(.c) u32 {
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

export fn fst_read_text(path: ?[*:0]const u8) callconv(.c) Handle {
    const p = path orelse return invalid_handle;
    const content = std.Io.Dir.cwd().readFileAlloc(defaultIo(), std.mem.span(p), alloc, .limited(64 * 1024 * 1024)) catch return invalid_handle;
    defer alloc.free(content);

    var fst = io_text.readText(W, alloc, content) catch return invalid_handle;
    api_mutex.lock();
    const h = newMutableHandle(fst);
    api_mutex.unlock();
    if (h == invalid_handle) fst.deinit();
    return h;
}

export fn fst_load(path: ?[*:0]const u8) callconv(.c) Handle {
    const p = path orelse return invalid_handle;
    const slice = std.mem.span(p);
    var fst = io_binary.readBinary(W, alloc, defaultIo(), slice) catch return invalid_handle;
    api_mutex.lock();
    const h = newFstHandle(fst);
    api_mutex.unlock();
    if (h == invalid_handle) fst.deinit();
    return h;
}

export fn fst_load_openfst(path: ?[*:0]const u8) callconv(.c) Handle {
    const p = path orelse return invalid_handle;
    const slice = std.mem.span(p);
    var fst = loadOpenFstViaFstPrint(slice) catch return invalid_handle;
    api_mutex.lock();
    const h = newFstHandle(fst);
    api_mutex.unlock();
    if (h == invalid_handle) fst.deinit();
    return h;
}

export fn fst_save(handle: Handle, path: ?[*:0]const u8) callconv(.c) FstError {
    const p = path orelse return .invalid_arg;
    api_mutex.lock();
    const h = fst_table.getConst(handle) orelse {
        api_mutex.unlock();
        return .invalid_arg;
    };
    var snapshot = cloneFstOwned(h) catch {
        api_mutex.unlock();
        return .oom;
    };
    api_mutex.unlock();
    defer snapshot.deinit();

    io_binary.writeBinary(W, &snapshot, defaultIo(), std.mem.span(p)) catch return .io_error;
    return .ok;
}

// ── Operations ──

export fn fst_compose(a_handle: Handle, b_handle: Handle) callconv(.c) Handle {
    api_mutex.lock();
    const ha = mutable_table.getConst(a_handle) orelse {
        api_mutex.unlock();
        return invalid_handle;
    };
    var a_snapshot = cloneMutableOwned(ha) catch {
        api_mutex.unlock();
        return invalid_handle;
    };
    const hb = mutable_table.getConst(b_handle) orelse {
        a_snapshot.deinit();
        api_mutex.unlock();
        return invalid_handle;
    };
    var b_snapshot = cloneMutableOwned(hb) catch {
        a_snapshot.deinit();
        api_mutex.unlock();
        return invalid_handle;
    };
    api_mutex.unlock();
    defer a_snapshot.deinit();
    defer b_snapshot.deinit();

    var result = compose_mod.compose(W, alloc, &a_snapshot, &b_snapshot) catch return invalid_handle;
    api_mutex.lock();
    const h = newMutableHandle(result);
    api_mutex.unlock();
    if (h == invalid_handle) result.deinit();
    return h;
}

export fn fst_compose_frozen(a_handle: Handle, b_handle: Handle) callconv(.c) Handle {
    const trace = isComposeTraceEnabled();
    const t0: i128 = if (trace) traceNowNs() else 0;

    api_mutex.lock();
    const ha = mutable_table.getConst(a_handle) orelse {
        api_mutex.unlock();
        if (trace) traceComposeFrozen("invalid_a", a_handle, b_handle, 0, 0, 0, 0, traceNowNs() - t0);
        return invalid_handle;
    };
    var a_snapshot = cloneMutableOwned(ha) catch {
        api_mutex.unlock();
        if (trace) traceComposeFrozen("clone_a_oom", a_handle, b_handle, 0, 0, 0, 0, traceNowNs() - t0);
        return invalid_handle;
    };
    const hb = fst_table.pinConst(b_handle) orelse {
        a_snapshot.deinit();
        api_mutex.unlock();
        if (trace) {
            traceComposeFrozen(
                "invalid_b",
                a_handle,
                b_handle,
                a_snapshot.numStates(),
                mutableTotalArcs(&a_snapshot),
                0,
                0,
                traceNowNs() - t0,
            );
        }
        return invalid_handle;
    };
    api_mutex.unlock();
    defer a_snapshot.deinit();
    defer {
        api_mutex.lock();
        _ = fst_table.unpin(b_handle, &fstDeinit);
        api_mutex.unlock();
    }

    const in_states: usize = if (trace) a_snapshot.numStates() else 0;
    const in_arcs: usize = if (trace) mutableTotalArcs(&a_snapshot) else 0;

    var result = compose_mod.compose(W, alloc, &a_snapshot, hb) catch {
        if (trace) traceComposeFrozen("compose_error", a_handle, b_handle, in_states, in_arcs, 0, 0, traceNowNs() - t0);
        return invalid_handle;
    };
    if (trace) {
        traceComposeFrozen(
            "ok",
            a_handle,
            b_handle,
            in_states,
            in_arcs,
            result.numStates(),
            mutableTotalArcs(&result),
            traceNowNs() - t0,
        );
    }
    api_mutex.lock();
    const h = newMutableHandle(result);
    api_mutex.unlock();
    if (h == invalid_handle) {
        if (trace) traceComposeFrozen("new_handle_oom", a_handle, b_handle, in_states, in_arcs, result.numStates(), mutableTotalArcs(&result), traceNowNs() - t0);
        result.deinit();
    }
    return h;
}

export fn fst_compose_frozen_shortest_path(a_handle: Handle, b_handle: Handle, n: u32) callconv(.c) Handle {
    const trace = isComposeTraceEnabled();
    const t0: i128 = if (trace) traceNowNs() else 0;

    api_mutex.lock();
    const ha = mutable_table.getConst(a_handle) orelse {
        api_mutex.unlock();
        if (trace) traceComposeFrozen("sp_invalid_a", a_handle, b_handle, 0, 0, 0, 0, traceNowNs() - t0);
        return invalid_handle;
    };
    var a_snapshot = cloneMutableOwned(ha) catch {
        api_mutex.unlock();
        if (trace) traceComposeFrozen("sp_clone_a_oom", a_handle, b_handle, 0, 0, 0, 0, traceNowNs() - t0);
        return invalid_handle;
    };
    const hb = fst_table.pinConst(b_handle) orelse {
        a_snapshot.deinit();
        api_mutex.unlock();
        if (trace) {
            traceComposeFrozen(
                "sp_invalid_b",
                a_handle,
                b_handle,
                a_snapshot.numStates(),
                mutableTotalArcs(&a_snapshot),
                0,
                0,
                traceNowNs() - t0,
            );
        }
        return invalid_handle;
    };
    api_mutex.unlock();
    defer a_snapshot.deinit();
    defer {
        api_mutex.lock();
        _ = fst_table.unpin(b_handle, &fstDeinit);
        api_mutex.unlock();
    }

    const in_states: usize = if (trace) a_snapshot.numStates() else 0;
    const in_arcs: usize = if (trace) mutableTotalArcs(&a_snapshot) else 0;

    var result = compose_shortest_path_mod.composeShortestPath(W, alloc, &a_snapshot, hb, n) catch {
        if (trace) traceComposeFrozen("sp_compose_error", a_handle, b_handle, in_states, in_arcs, 0, 0, traceNowNs() - t0);
        return invalid_handle;
    };
    if (trace) {
        traceComposeFrozen(
            "sp_ok",
            a_handle,
            b_handle,
            in_states,
            in_arcs,
            result.numStates(),
            mutableTotalArcs(&result),
            traceNowNs() - t0,
        );
    }
    api_mutex.lock();
    const h = newMutableHandle(result);
    api_mutex.unlock();
    if (h == invalid_handle) {
        if (trace) traceComposeFrozen("sp_new_handle_oom", a_handle, b_handle, in_states, in_arcs, result.numStates(), mutableTotalArcs(&result), traceNowNs() - t0);
        result.deinit();
    }
    return h;
}

export fn fst_determinize(handle: Handle) callconv(.c) Handle {
    api_mutex.lock();
    const h = mutable_table.getConst(handle) orelse {
        api_mutex.unlock();
        return invalid_handle;
    };
    var snapshot = cloneMutableOwned(h) catch {
        api_mutex.unlock();
        return invalid_handle;
    };
    api_mutex.unlock();
    defer snapshot.deinit();

    var result = determinize_mod.determinize(W, alloc, &snapshot) catch return invalid_handle;
    api_mutex.lock();
    const rh = newMutableHandle(result);
    api_mutex.unlock();
    if (rh == invalid_handle) result.deinit();
    return rh;
}

export fn fst_minimize(handle: Handle) callconv(.c) FstError {
    api_mutex.lock();
    const h = mutable_table.getConst(handle) orelse {
        api_mutex.unlock();
        return .invalid_arg;
    };
    const expect_generation = mutable_table.generation(handle) orelse {
        api_mutex.unlock();
        return .invalid_arg;
    };
    var snapshot = cloneMutableOwned(h) catch {
        api_mutex.unlock();
        return .oom;
    };
    api_mutex.unlock();

    var keep_snapshot = true;
    defer if (keep_snapshot) snapshot.deinit();
    minimize_mod.minimize(W, alloc, &snapshot) catch return .oom;

    api_mutex.lock();
    const dst = mutable_table.get(handle) orelse {
        api_mutex.unlock();
        return .invalid_arg;
    };
    const current_generation = mutable_table.generation(handle) orelse {
        api_mutex.unlock();
        return .invalid_arg;
    };
    if (current_generation != expect_generation) {
        api_mutex.unlock();
        return .invalid_arg;
    }
    var old = dst.*;
    dst.* = snapshot;
    keep_snapshot = false;
    _ = mutable_table.bumpGeneration(handle);
    api_mutex.unlock();
    old.deinit();
    return .ok;
}

export fn fst_rm_epsilon(handle: Handle) callconv(.c) Handle {
    api_mutex.lock();
    const h = mutable_table.getConst(handle) orelse {
        api_mutex.unlock();
        return invalid_handle;
    };
    var snapshot = cloneMutableOwned(h) catch {
        api_mutex.unlock();
        return invalid_handle;
    };
    api_mutex.unlock();
    defer snapshot.deinit();

    var result = rm_epsilon_mod.rmEpsilon(W, alloc, &snapshot) catch return invalid_handle;
    api_mutex.lock();
    const rh = newMutableHandle(result);
    api_mutex.unlock();
    if (rh == invalid_handle) result.deinit();
    return rh;
}

export fn fst_shortest_path(handle: Handle, n: u32) callconv(.c) Handle {
    api_mutex.lock();
    const h = mutable_table.getConst(handle) orelse {
        api_mutex.unlock();
        return invalid_handle;
    };
    var snapshot = cloneMutableOwned(h) catch {
        api_mutex.unlock();
        return invalid_handle;
    };
    api_mutex.unlock();
    defer snapshot.deinit();

    var result = shortest_path_mod.shortestPath(W, alloc, &snapshot, n) catch return invalid_handle;
    api_mutex.lock();
    const rh = newMutableHandle(result);
    api_mutex.unlock();
    if (rh == invalid_handle) result.deinit();
    return rh;
}

export fn fst_union(a_handle: Handle, b_handle: Handle) callconv(.c) FstError {
    api_mutex.lock();
    const ha = mutable_table.getConst(a_handle) orelse {
        api_mutex.unlock();
        return .invalid_arg;
    };
    const expect_generation = mutable_table.generation(a_handle) orelse {
        api_mutex.unlock();
        return .invalid_arg;
    };
    var a_snapshot = cloneMutableOwned(ha) catch {
        api_mutex.unlock();
        return .oom;
    };
    const hb = mutable_table.getConst(b_handle) orelse {
        a_snapshot.deinit();
        api_mutex.unlock();
        return .invalid_arg;
    };
    var b_snapshot = cloneMutableOwned(hb) catch {
        a_snapshot.deinit();
        api_mutex.unlock();
        return .oom;
    };
    api_mutex.unlock();

    var keep_a_snapshot = true;
    defer if (keep_a_snapshot) a_snapshot.deinit();
    defer b_snapshot.deinit();
    union_mod.union_(W, &a_snapshot, &b_snapshot) catch return .oom;

    api_mutex.lock();
    const dst = mutable_table.get(a_handle) orelse {
        api_mutex.unlock();
        return .invalid_arg;
    };
    const current_generation = mutable_table.generation(a_handle) orelse {
        api_mutex.unlock();
        return .invalid_arg;
    };
    if (current_generation != expect_generation) {
        api_mutex.unlock();
        return .invalid_arg;
    }
    var old = dst.*;
    dst.* = a_snapshot;
    keep_a_snapshot = false;
    _ = mutable_table.bumpGeneration(a_handle);
    api_mutex.unlock();
    old.deinit();
    return .ok;
}

export fn fst_concat(a_handle: Handle, b_handle: Handle) callconv(.c) FstError {
    api_mutex.lock();
    const ha = mutable_table.getConst(a_handle) orelse {
        api_mutex.unlock();
        return .invalid_arg;
    };
    const expect_generation = mutable_table.generation(a_handle) orelse {
        api_mutex.unlock();
        return .invalid_arg;
    };
    var a_snapshot = cloneMutableOwned(ha) catch {
        api_mutex.unlock();
        return .oom;
    };
    const hb = mutable_table.getConst(b_handle) orelse {
        a_snapshot.deinit();
        api_mutex.unlock();
        return .invalid_arg;
    };
    var b_snapshot = cloneMutableOwned(hb) catch {
        a_snapshot.deinit();
        api_mutex.unlock();
        return .oom;
    };
    api_mutex.unlock();

    var keep_a_snapshot = true;
    defer if (keep_a_snapshot) a_snapshot.deinit();
    defer b_snapshot.deinit();
    concat_mod.concat(W, &a_snapshot, &b_snapshot) catch return .oom;

    api_mutex.lock();
    const dst = mutable_table.get(a_handle) orelse {
        api_mutex.unlock();
        return .invalid_arg;
    };
    const current_generation = mutable_table.generation(a_handle) orelse {
        api_mutex.unlock();
        return .invalid_arg;
    };
    if (current_generation != expect_generation) {
        api_mutex.unlock();
        return .invalid_arg;
    }
    var old = dst.*;
    dst.* = a_snapshot;
    keep_a_snapshot = false;
    _ = mutable_table.bumpGeneration(a_handle);
    api_mutex.unlock();
    old.deinit();
    return .ok;
}

export fn fst_closure(handle: Handle, closure_type: c_int) callconv(.c) FstError {
    const ct: closure_mod.ClosureType = switch (closure_type) {
        0 => .star,
        1 => .plus,
        2 => .ques,
        else => return .invalid_arg,
    };

    api_mutex.lock();
    const h = mutable_table.getConst(handle) orelse {
        api_mutex.unlock();
        return .invalid_arg;
    };
    const expect_generation = mutable_table.generation(handle) orelse {
        api_mutex.unlock();
        return .invalid_arg;
    };
    var snapshot = cloneMutableOwned(h) catch {
        api_mutex.unlock();
        return .oom;
    };
    api_mutex.unlock();

    var keep_snapshot = true;
    defer if (keep_snapshot) snapshot.deinit();
    closure_mod.closure(W, &snapshot, ct) catch return .oom;

    api_mutex.lock();
    const dst = mutable_table.get(handle) orelse {
        api_mutex.unlock();
        return .invalid_arg;
    };
    const current_generation = mutable_table.generation(handle) orelse {
        api_mutex.unlock();
        return .invalid_arg;
    };
    if (current_generation != expect_generation) {
        api_mutex.unlock();
        return .invalid_arg;
    }
    var old = dst.*;
    dst.* = snapshot;
    keep_snapshot = false;
    _ = mutable_table.bumpGeneration(handle);
    api_mutex.unlock();
    old.deinit();
    return .ok;
}

export fn fst_invert(handle: Handle) callconv(.c) void {
    api_mutex.lock();
    const h = mutable_table.getConst(handle) orelse {
        api_mutex.unlock();
        return;
    };
    const expect_generation = mutable_table.generation(handle) orelse {
        api_mutex.unlock();
        return;
    };
    var snapshot = cloneMutableOwned(h) catch {
        api_mutex.unlock();
        return;
    };
    api_mutex.unlock();

    var keep_snapshot = true;
    defer if (keep_snapshot) snapshot.deinit();
    invert_mod.invert(W, &snapshot);

    api_mutex.lock();
    const dst = mutable_table.get(handle) orelse {
        api_mutex.unlock();
        return;
    };
    const current_generation = mutable_table.generation(handle) orelse {
        api_mutex.unlock();
        return;
    };
    if (current_generation != expect_generation) {
        api_mutex.unlock();
        return;
    }
    var old = dst.*;
    dst.* = snapshot;
    keep_snapshot = false;
    _ = mutable_table.bumpGeneration(handle);
    api_mutex.unlock();
    old.deinit();
}

export fn fst_optimize(handle: Handle) callconv(.c) Handle {
    api_mutex.lock();
    const h = mutable_table.getConst(handle) orelse {
        api_mutex.unlock();
        return invalid_handle;
    };
    var snapshot = cloneMutableOwned(h) catch {
        api_mutex.unlock();
        return invalid_handle;
    };
    api_mutex.unlock();
    defer snapshot.deinit();

    var result = optimize_mod.optimize(W, alloc, &snapshot) catch return invalid_handle;
    api_mutex.lock();
    const rh = newMutableHandle(result);
    api_mutex.unlock();
    if (rh == invalid_handle) result.deinit();
    return rh;
}

export fn fst_cdrewrite(tau_h: Handle, lambda_h: Handle, rho_h: Handle, sigma_h: Handle) callconv(.c) Handle {
    api_mutex.lock();
    const t = mutable_table.getConst(tau_h) orelse {
        api_mutex.unlock();
        return invalid_handle;
    };
    var t_snapshot = cloneMutableOwned(t) catch {
        api_mutex.unlock();
        return invalid_handle;
    };
    const l = mutable_table.getConst(lambda_h) orelse {
        t_snapshot.deinit();
        api_mutex.unlock();
        return invalid_handle;
    };
    var l_snapshot = cloneMutableOwned(l) catch {
        t_snapshot.deinit();
        api_mutex.unlock();
        return invalid_handle;
    };
    const r = mutable_table.getConst(rho_h) orelse {
        l_snapshot.deinit();
        t_snapshot.deinit();
        api_mutex.unlock();
        return invalid_handle;
    };
    var r_snapshot = cloneMutableOwned(r) catch {
        l_snapshot.deinit();
        t_snapshot.deinit();
        api_mutex.unlock();
        return invalid_handle;
    };
    const s = mutable_table.getConst(sigma_h) orelse {
        r_snapshot.deinit();
        l_snapshot.deinit();
        t_snapshot.deinit();
        api_mutex.unlock();
        return invalid_handle;
    };
    var s_snapshot = cloneMutableOwned(s) catch {
        r_snapshot.deinit();
        l_snapshot.deinit();
        t_snapshot.deinit();
        api_mutex.unlock();
        return invalid_handle;
    };
    api_mutex.unlock();
    defer t_snapshot.deinit();
    defer l_snapshot.deinit();
    defer r_snapshot.deinit();
    defer s_snapshot.deinit();

    var result = rewrite_mod.cdrewrite(W, alloc, &t_snapshot, &l_snapshot, &r_snapshot, &s_snapshot) catch return invalid_handle;
    api_mutex.lock();
    const rh = newMutableHandle(result);
    api_mutex.unlock();
    if (rh == invalid_handle) result.deinit();
    return rh;
}

export fn fst_difference(a_handle: Handle, b_handle: Handle) callconv(.c) Handle {
    api_mutex.lock();
    const ha = mutable_table.getConst(a_handle) orelse {
        api_mutex.unlock();
        return invalid_handle;
    };
    var a_snapshot = cloneMutableOwned(ha) catch {
        api_mutex.unlock();
        return invalid_handle;
    };
    const hb = mutable_table.getConst(b_handle) orelse {
        a_snapshot.deinit();
        api_mutex.unlock();
        return invalid_handle;
    };
    var b_snapshot = cloneMutableOwned(hb) catch {
        a_snapshot.deinit();
        api_mutex.unlock();
        return invalid_handle;
    };
    api_mutex.unlock();
    defer a_snapshot.deinit();
    defer b_snapshot.deinit();

    var result = difference_mod.difference(W, alloc, &a_snapshot, &b_snapshot) catch return invalid_handle;
    api_mutex.lock();
    const h = newMutableHandle(result);
    api_mutex.unlock();
    if (h == invalid_handle) result.deinit();
    return h;
}

export fn fst_replace(root_handle: Handle, labels: ?[*]const u32, fst_handles: ?[*]const Handle, num_pairs: u32) callconv(.c) Handle {
    const lbl_ptr = labels orelse return invalid_handle;
    const fst_ptr = fst_handles orelse return invalid_handle;

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const labels_copy = arena.dupe(u32, lbl_ptr[0..num_pairs]) catch return invalid_handle;
    const handles_copy = arena.dupe(Handle, fst_ptr[0..num_pairs]) catch return invalid_handle;

    const snapshots = alloc.alloc(MutableFst, num_pairs) catch return invalid_handle;
    defer alloc.free(snapshots);
    var cloned_count: usize = 0;
    defer {
        for (0..cloned_count) |i| {
            snapshots[i].deinit();
        }
    }

    api_mutex.lock();
    const root = mutable_table.getConst(root_handle) orelse {
        api_mutex.unlock();
        return invalid_handle;
    };
    var root_snapshot = cloneMutableOwned(root) catch {
        api_mutex.unlock();
        return invalid_handle;
    };
    for (0..num_pairs) |i| {
        const fst_h = mutable_table.getConst(handles_copy[i]) orelse {
            root_snapshot.deinit();
            api_mutex.unlock();
            return invalid_handle;
        };
        snapshots[i] = cloneMutableOwned(fst_h) catch {
            root_snapshot.deinit();
            api_mutex.unlock();
            return invalid_handle;
        };
        cloned_count += 1;
    }
    api_mutex.unlock();
    defer root_snapshot.deinit();

    const pairs = arena.alloc(replace_mod.ReplacePair(W), num_pairs) catch return invalid_handle;
    for (0..num_pairs) |i| {
        pairs[i] = .{ .label = labels_copy[i], .fst = &snapshots[i] };
    }

    var result = replace_mod.replace(W, alloc, &root_snapshot, pairs) catch return invalid_handle;
    api_mutex.lock();
    const h = newMutableHandle(result);
    api_mutex.unlock();
    if (h == invalid_handle) result.deinit();
    return h;
}

export fn fst_project(handle: Handle, side: c_int) callconv(.c) void {
    const pt: project_mod.ProjectType = switch (side) {
        0 => .input,
        1 => .output,
        else => return,
    };

    api_mutex.lock();
    const h = mutable_table.getConst(handle) orelse {
        api_mutex.unlock();
        return;
    };
    const expect_generation = mutable_table.generation(handle) orelse {
        api_mutex.unlock();
        return;
    };
    var snapshot = cloneMutableOwned(h) catch {
        api_mutex.unlock();
        return;
    };
    api_mutex.unlock();

    var keep_snapshot = true;
    defer if (keep_snapshot) snapshot.deinit();
    project_mod.project(W, &snapshot, pt);

    api_mutex.lock();
    const dst = mutable_table.get(handle) orelse {
        api_mutex.unlock();
        return;
    };
    const current_generation = mutable_table.generation(handle) orelse {
        api_mutex.unlock();
        return;
    };
    if (current_generation != expect_generation) {
        api_mutex.unlock();
        return;
    }
    var old = dst.*;
    dst.* = snapshot;
    keep_snapshot = false;
    _ = mutable_table.bumpGeneration(handle);
    api_mutex.unlock();
    old.deinit();
}

// ── String utilities ──

export fn fst_compile_string(input: ?[*]const u8, len: u32) callconv(.c) Handle {
    api_mutex.lock();
    defer api_mutex.unlock();
    const i = input orelse return invalid_handle;
    var fst = string_mod.compileString(W, alloc, i[0..len]) catch return invalid_handle;
    const h = newMutableHandle(fst);
    if (h == invalid_handle) fst.deinit();
    return h;
}

export fn fst_print_string(handle: Handle, buf: ?[*]u8, buf_len: u32) callconv(.c) i32 {
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

export fn fst_print_output_string(handle: Handle, buf: ?[*]u8, buf_len: u32) callconv(.c) i32 {
    api_mutex.lock();
    defer api_mutex.unlock();
    const h = mutable_table.getConst(handle) orelse return -1;
    const result = string_mod.printOutputString(W, alloc, h) catch return -1;
    const s = result orelse return -1;
    defer alloc.free(s);

    if (s.len > buf_len) return -1;
    if (buf) |b| {
        @memcpy(b[0..s.len], s);
    }
    return @intCast(s.len);
}

// ── Mutable query (for C consumers) ──

export fn fst_mutable_start(handle: Handle) callconv(.c) u32 {
    api_mutex.lock();
    defer api_mutex.unlock();
    const h = mutable_table.getConst(handle) orelse return no_state;
    return h.start();
}

export fn fst_mutable_num_states(handle: Handle) callconv(.c) u32 {
    api_mutex.lock();
    defer api_mutex.unlock();
    const h = mutable_table.getConst(handle) orelse return 0;
    return @intCast(h.numStates());
}

export fn fst_mutable_num_arcs(handle: Handle, state: u32) callconv(.c) u32 {
    api_mutex.lock();
    defer api_mutex.unlock();
    const h = mutable_table.getConst(handle) orelse return 0;
    if (state >= h.numStates()) return 0;
    return @intCast(h.numArcs(state));
}

export fn fst_mutable_final_weight(handle: Handle, state: u32) callconv(.c) f64 {
    api_mutex.lock();
    defer api_mutex.unlock();
    const h = mutable_table.getConst(handle) orelse return std.math.inf(f64);
    if (state >= h.numStates()) return std.math.inf(f64);
    return h.finalWeight(state).value;
}

export fn fst_mutable_get_arcs(handle: Handle, state: u32, buf: ?[*]CFstArc, buf_len: u32) callconv(.c) u32 {
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

test "c-api: freed handle cannot access reused slot" {
    const first = fst_mutable_new();
    try std.testing.expect(first != invalid_handle);
    fst_mutable_free(first);

    const second = fst_mutable_new();
    defer fst_mutable_free(second);
    try std.testing.expect(second != invalid_handle);
    try std.testing.expect(first != second);
    try std.testing.expectEqual(no_state, fst_mutable_add_state(first));
    try std.testing.expectEqual(@as(u32, 0), fst_mutable_add_state(second));
}
