# Zig Memory Management Patterns & Pitfalls

Comprehensive reference for Zig memory management, distilled from core team guidance, community experts, and battle-tested patterns. Targets Zig 0.15+.

---

## Table of Contents

1. [Design Philosophy](#design-philosophy)
2. [Allocator Types & When to Use](#allocator-types--when-to-use)
3. [Arena Allocator Patterns](#arena-allocator-patterns)
4. [Lifetime & Ownership Rules](#lifetime--ownership-rules)
5. [Dangling Pointer Pitfalls](#dangling-pointer-pitfalls)
6. [Slice & Iterator Invalidation](#slice--iterator-invalidation)
7. [defer / errdefer Patterns](#defer--errdefer-patterns)
8. [HashMap Memory Pitfalls](#hashmap-memory-pitfalls)
9. [C FFI Memory Boundaries](#c-ffi-memory-boundaries)
10. [Testing & Leak Detection](#testing--leak-detection)
11. [What Zig Catches vs. Doesn't](#what-zig-catches-vs-doesnt)
12. [Sources](#sources)

---

## Design Philosophy

Zig's core memory principle: **no hidden allocations, no hidden control flow**.

- Every function that allocates must accept an `Allocator` parameter
- There is no global allocator; the caller always decides the strategy
- Library code exposes `Allocator` so users pick arena/GPA/pool/etc.
- "Where are the bytes?" is the question Zig forces you to answer explicitly

> Andrew Kelley: "Zig takes a different approach to memory allocation. It
> requires you to pass a custom allocator when you need one, which means
> there are no hidden memory allocations."

---

## Allocator Types & When to Use

| Allocator | Use Case | Tradeoff |
|-----------|----------|----------|
| `std.heap.page_allocator` | Backing allocator, large blocks | Slow, wastes memory (page-granularity) |
| `std.heap.ArenaAllocator` | Short-lived bulk allocations (per-request, per-algorithm) | Fast alloc, no individual free, bulk deinit |
| `std.heap.DebugAllocator` (was GPA) | Development/testing | Detects double-free, UAF, leaks; slow |
| `std.heap.FixedBufferAllocator` | Bounded, stack-sized, zero-heap | Fixed capacity, fails on overflow |
| `std.heap.MemoryPool(T)` | High-frequency create/destroy of single type | Fast via free-list reuse; type must be >= pointer size |
| `std.heap.c_allocator` | C interop, when you need malloc/free | No safety checks |
| `std.testing.allocator` | Unit tests | Auto leak detection on scope exit |

### Decision Flow

```
Need dynamic allocation?
  |
  +-- Short-lived, bulk cleanup? --> ArenaAllocator
  |
  +-- Single type, high churn?  --> MemoryPool(T)
  |
  +-- Known upper bound?        --> FixedBufferAllocator
  |
  +-- General purpose, debug?   --> DebugAllocator
  |
  +-- C FFI boundary?           --> c_allocator (or wrap in handle table)
  |
  +-- Unit tests?               --> std.testing.allocator
```

---

## Arena Allocator Patterns

### Basic: One Arena per Operation

```zig
pub fn processRequest(parent_alloc: Allocator, req: Request) !Response {
    var arena = std.heap.ArenaAllocator.init(parent_alloc);
    defer arena.deinit();  // all temps freed in one shot
    const alloc = arena.allocator();

    // all temporary allocations use `alloc`
    const parsed = try parse(alloc, req.body);
    const result = try transform(alloc, parsed);

    // only the returned value uses parent_alloc
    return try result.clone(parent_alloc);
}
```

### Reuse: Arena with Retain Limit (Hot Loops)

```zig
var arena = std.heap.ArenaAllocator.init(allocator);
defer arena.deinit();

while (queue.pop()) |item| {
    defer _ = arena.reset(.{ .retain_with_limit = 8192 });
    // process item using arena.allocator()
}
```

This avoids repeated OS-level alloc/free per iteration. The arena keeps up to 8KB allocated between iterations.

### Performance: FixedBuffer + Arena Fallback

```zig
// Pre-allocate a stack buffer for the common case
var buf: [4096]u8 = undefined;
var fba = std.heap.FixedBufferAllocator.init(&buf);

var arena = std.heap.ArenaAllocator.init(parent_alloc);
defer arena.deinit();

// Try fixed buffer first (fast), fall back to arena (heap)
const alloc = fba.allocator();  // or build a custom fallback allocator
```

### Anti-Pattern: Arena on Stack, Pointer Escapes

```zig
// BAD: allocator captures address of stack-local arena
fn init(parent: Allocator) Self {
    var arena = ArenaAllocator.init(parent);
    const alloc = arena.allocator();  // captures &arena (stack address!)
    return .{
        .arena = arena,      // arena is COPIED to return value
        .allocator = alloc,  // still points to old stack address!
    };
}
```

**Fix**: Heap-allocate the arena:

```zig
fn init(parent: Allocator) !Self {
    const arena = try parent.create(ArenaAllocator);
    arena.* = ArenaAllocator.init(parent);
    return .{
        .arena = arena,
        .allocator = arena.allocator(),  // points to heap
    };
}
```

### Rule: Arena.free() is Almost Always a No-Op

`ArenaAllocator.free()` only works if you free the **most recent** allocation. Out-of-order frees do nothing. Don't rely on it. Use `arena.deinit()` or `arena.reset()`.

---

## Lifetime & Ownership Rules

### Rule 1: Whoever Allocates, Documents Who Frees

```zig
/// Caller owns the returned slice. Free with `allocator.free(result)`.
pub fn encode(allocator: Allocator, input: []const u8) ![]u8 { ... }
```

### Rule 2: errdefer for Partial Construction

```zig
pub fn init(allocator: Allocator) !Self {
    const buf = try allocator.alloc(u8, 1024);
    errdefer allocator.free(buf);  // freed if anything below fails

    const table = try allocator.alloc(Entry, 256);
    errdefer allocator.free(table);

    return .{ .buf = buf, .table = table };
}
```

### Rule 3: Clone for Ownership Transfer

When passing data across lifetime boundaries, clone into the target's allocator:

```zig
// Result lives in caller's allocator, not the arena
var result = try computeWithArena(arena_alloc, input);
return try result.clone(caller_alloc);
```

### Rule 4: Assignment is Always a Copy

```zig
var a = ArenaAllocator.init(alloc);
var b = a;  // b is an independent COPY of a
// a and b now manage different state!
```

This is the root cause of many arena bugs. When in doubt, use pointers.

---

## Dangling Pointer Pitfalls

### Pitfall 1: Returning Stack References

```zig
// BAD: buf lives on stack, freed when function returns
fn format(x: i32) []u8 {
    var buf: [20]u8 = undefined;
    return std.fmt.bufPrint(&buf, "{d}", .{x});  // dangling!
}
```

**Fix**: Accept a caller-provided buffer, or heap-allocate with `allocPrint`.

### Pitfall 2: ArrayList Append Invalidates Pointers

```zig
var list = std.ArrayList(User).init(allocator);
try list.append(.{ .name = "a" });
const ptr = &list.items[0];  // pointer into list's internal buffer

try list.append(.{ .name = "b" });  // may realloc, ptr now dangling!
ptr.name = "modified";  // UNDEFINED BEHAVIOR
```

**Fix**: Don't hold pointers across mutations. Re-index after modification.

### Pitfall 3: HashMap getPtr + Modification

```zig
const entry = map.getPtr("key").?;
try map.put("other", value);  // may trigger rehash
entry.* = new_value;  // DANGLING: entry pointer invalidated by put
```

---

## Slice & Iterator Invalidation

### When Slices Become Invalid

| Operation | Invalidates |
|-----------|-------------|
| `ArrayList.append` / `appendSlice` | All existing `items` slices and pointers |
| `ArrayList.resize` / `ensureTotalCapacity` | All existing slices if realloc occurs |
| `HashMap.put` / `getOrPut` | All `getPtr` results, iterator pointers |
| `HashMap.remove` | The specific entry's pointer |
| `ArenaAllocator.deinit` / `reset` | ALL memory allocated from this arena |
| `MutableFst.addState` / `addArc` | Arc slices from `fst.arcs(s)` |

### Generation Counter Pattern (Used in libfst)

```zig
const snapshot = fst.gen();
const arc_slice = fst.arcs(state);
// ... use arc_slice ...
fst.checkGeneration(snapshot);  // asserts no mutation occurred
```

---

## defer / errdefer Patterns

### Basic: Pair Alloc with Defer Free

```zig
const buf = try allocator.alloc(u8, size);
defer allocator.free(buf);
```

### errdefer: Cleanup on Error Only

```zig
const resource = try acquire();
errdefer release(resource);  // only runs if function returns error
// ... more code that may fail ...
return .{ .resource = resource };  // on success, caller owns it
```

### Advanced: Assert Postconditions

```zig
fn process(self: *Self) void {
    std.debug.assert(self.state == .ready);
    defer std.debug.assert(self.state == .done);
    // ... complex state machine logic ...
}
```

### Advanced: Compile-Time No-Error Guarantee

```zig
fn rehash(self: *Self) !void {
    var new_table = try allocateNewTable();  // may fail
    errdefer comptime unreachable;  // from here, nothing may fail
    // ... move entries (infallible) ...
}
```

### Advanced: Error Logging

```zig
const port = blk: {
    errdefer |err| log.err("failed to read port: {}", .{err});
    break :blk try parsePort(input);
};
```

### Insight from matklad

> "defer prevents RAII-style programming, and that's a feature. It
> encourages pooling resources (arena/pool) rather than per-object
> lifecycle management."

---

## HashMap Memory Pitfalls

### Who Owns Keys and Values?

HashMap stores copies of keys and values. If they contain heap pointers, you must free them manually:

```zig
// Cleanup pattern for StringHashMap(*User)
defer {
    var it = map.iterator();
    while (it.next()) |kv| {
        allocator.free(kv.key_ptr.*);      // free string key
        allocator.destroy(kv.value_ptr.*); // free User object
    }
    map.deinit();
}
```

### remove() vs fetchRemove()

```zig
_ = map.remove(key);  // key/value gone, can't free heap pointers!

if (map.fetchRemove(key)) |kv| {
    allocator.free(kv.key);    // fetchRemove returns actual values
    allocator.destroy(kv.value);
}
```

### getOrPut() for Efficient Upsert

```zig
const gop = try map.getOrPut(key);
if (!gop.found_existing) {
    gop.key_ptr.* = try allocator.dupe(u8, key);
    gop.value_ptr.* = initial_value;
} else {
    gop.value_ptr.* += 1;
}
```

---

## C FFI Memory Boundaries

### Handle Table Pattern (Used in libfst)

Never expose raw Zig pointers to C. Use opaque integer handles:

```zig
fn HandleTable(comptime T: type) type {
    return struct {
        slots: ArrayListUnmanaged(?*T) = .{},
        free_list: ArrayListUnmanaged(u32) = .{},

        fn insert(self: *@This(), ptr: *T) u32 { ... }
        fn get(self: *@This(), handle: u32) ?*T { ... }
        fn remove(self: *@This(), handle: u32) bool { ... }
    };
}
```

This prevents:
- **Double-free**: slot is null on second call
- **Use-after-free**: freed slot returns null
- **Type confusion**: separate tables per type

### C Header Uses Integer Handles

```c
typedef uint32_t FstHandle;
#define FST_INVALID_HANDLE UINT32_MAX

FstHandle fst_create(void);
void fst_free(FstHandle h);  // safe to call twice (second is no-op)
```

### Allocation Pairing Rule

Document clearly which side (Zig or C) owns each allocation:

```c
// Caller-allocated buffer, callee fills it:
uint32_t fst_get_arcs(FstHandle h, uint32_t state, FstArc* buf, uint32_t buf_len);

// Callee allocates, caller must free:
// (AVOID this pattern at FFI boundaries — prefer caller-allocated buffers)
```

---

## Testing & Leak Detection

### std.testing.allocator

Automatically detects leaks when the test scope exits:

```zig
test "no leaks" {
    const allocator = std.testing.allocator;  // panics on leak
    var list = std.ArrayList(u8).init(allocator);
    defer list.deinit();
    try list.append(42);
}
```

### DebugAllocator (formerly GPA)

For non-test code, wrap your allocator:

```zig
var debug = std.heap.DebugAllocator(.{}).init(std.heap.page_allocator);
defer _ = debug.deinit();  // prints leak report
const allocator = debug.allocator();
```

Detects:
- Double-free (crashes with stack trace)
- Use-after-free (fills freed memory with `0xDD`)
- Memory leaks (reports on deinit)
- Wrong `old_mem.len` passed to free

### FailingAllocator for OOM Testing

```zig
test "handles OOM gracefully" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 3,  // fail on 4th allocation
    });
    const result = myFunction(failing.allocator());
    try std.testing.expectError(error.OutOfMemory, result);
}
```

### checkAllAllocationFailures (Systematic OOM)

Runs your function N times, failing a different allocation each time:

```zig
test "all allocation failures handled" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testImpl, .{});
}
```

---

## What Zig Catches vs. Doesn't

### Zig Catches (Runtime, Debug Builds)

| Check | Example |
|-------|---------|
| Array/slice bounds | `slice[i]` where `i >= len` |
| Null pointer deref | `optional.?` when null |
| Integer overflow | `a + b` overflows u32 |
| Alignment violation | `@ptrCast` with wrong alignment |
| Unreachable reached | `unreachable` executed |
| Stack overflow | Deep recursion |
| Undefined value use | Reading `= undefined` variables |

### Zig Does NOT Catch

| Bug | Description |
|-----|-------------|
| Use-after-free | Accessing freed heap memory |
| Dangling stack pointers | Returning &local from function |
| Iterator invalidation | Holding slice across container mutation |
| Data races | Concurrent mutation without synchronization |
| Logical double-free | Freeing same pointer from two owners |
| Memory leaks | Forgetting to free (except with testing.allocator) |

### Mitigation Strategies for libfst

| Risk | Mitigation |
|------|-----------|
| Stale arc slices | Generation counter on MutableFst |
| Temp allocation leaks | Arena per algorithm |
| C API double-free/UAF | Handle table (u32 indices, not pointers) |
| Contiguous layout safety | Frozen Fst is immutable, index-based access |

---

## Sources

### Core / Official
- [Zig Language Reference - Memory](https://ziglang.org/documentation/master/)
- [zig.guide - Allocators](https://zig.guide/standard-library/allocators/)
- [zighelp.org - Standard Patterns](https://zighelp.org/chapter-2/)

### Karl Seguin (openmymind.net) — Practical Patterns
- [Leveraging Zig's Allocators](https://www.openmymind.net/Leveraging-Zigs-Allocators/) — Arena reuse, FallbackAllocator
- [Zig Dangling Pointers](https://www.openmymind.net/Zig-Dangling-Pointers/) — Stack escape, arena pointer bugs
- [Be Careful When Assigning ArenaAllocators](https://www.openmymind.net/Be-Careful-When-Assigning-ArenaAllocators/) — Copy semantics pitfall
- [ArenaAllocator.free and Nested Arenas](https://www.openmymind.net/ArenaAllocator-free-and-Nested-Arenas/) — free() is a no-op
- [Zig's HashMap Part 2](https://www.openmymind.net/Zigs-HashMap-Part-2/) — Key/value ownership
- [Zig's MemoryPool Allocator](https://www.openmymind.net/Zig-MemoryPool-Allocator/) — Free-list reuse
- [Allocator.resize](https://www.openmymind.net/Allocator-resize/) — resize doesn't update len
- [Heap Memory & Allocators](https://www.openmymind.net/learning_zig/heap_memory/) — Intro tutorial

### Critical Analysis
- [How (memory) safe is zig? — scattered-thoughts.net](https://www.scattered-thoughts.net/writing/how-safe-is-zig/) — Zig vs Rust safety comparison
- [Zig defer Patterns — matklad](https://matklad.github.io/2024/03/21/defer-patterns.html) — Advanced defer, anti-RAII insight

### Community
- [Zig Bits 0x1: Returning slices — Orhun](https://blog.orhun.dev/zig-bits-01/) — Dangling slice returns
- [Zig Bits 0x2: Defeating memory leaks — Orhun](https://blog.orhun.dev/zig-bits-02/) — defer/errdefer
- [Cool Zig Patterns: Gotta alloc fast — zig.news](https://zig.news/xq/cool-zig-patterns-gotta-alloc-fast-23h) — MemoryPool, allocation speed
- [GPA is Dead, Long Live DebugAllocator — ziggit.dev](https://ziggit.dev/t/gpa-is-dead-long-live-the-debug-allocator/8449)
- [Testing memory allocation failures — Lager](https://www.lagerdata.com/articles/testing-memory-allocation-failures-with-zig)
- [checkAllAllocationFailures — ryanliptak.com](https://www.ryanliptak.com/blog/zig-intro-to-check-all-allocation-failures/)

### Andrew Kelley / Core Team
- [Introduction to Zig — andrewkelley.me](https://andrewkelley.me/post/intro-to-zig.html) — No hidden allocations
- [Practical Data-Oriented Design talk](https://www.josherich.me/podcast/andrew-kelley-practical-data-oriented-design-dod) — Alignment, cache-friendly layout
- [zig-general-purpose-allocator — GitHub](https://github.com/andrewrk/zig-general-purpose-allocator) — GPA design rationale
