# libfst

A Finite State Transducer library in Zig, inspired by [OpenFST](https://www.openfst.org/) and [WeTextProcessing](https://github.com/wenet-e2e/WeTextProcessing).

## Quick Reference

### Zig Docs Lookup

Use `zigdoc` CLI to query Zig 0.15 standard library docs instantly:

```bash
zigdoc std.ArrayList            # type functions
zigdoc std.mem.Allocator        # structs & methods
zigdoc std.hash_map             # namespaces
zigdoc std.Build.addLibrary     # build system API
zigdoc --dump-imports           # list modules from build.zig
```

This is faster than web search for Zig API questions. Works with any `@import`-ed module in `build.zig`.

## Build & Test

```bash
zig build              # build static library + C header
zig build test         # run unit tests
zig build prop         # property-based tests (semiring laws, idempotency)
zig build fuzz         # fuzz test harness
zig build diff         # diff tests vs Pynini golden outputs (needs corpus)
```

## Project Structure

```
src/
  weight.zig          # TropicalWeight, LogWeight (f64 semirings)
  arc.zig             # Arc(W), Label (u32), StateId (u32)
  sym.zig             # SymbolTable: string <-> Label mapping
  mutable-fst.zig     # MutableFst(W): build-time mutable FST
  fst.zig             # Fst(W): frozen immutable FST (contiguous layout)
  string.zig          # compileString / printString
  char-class.zig      # BYTE, ALPHA, DIGIT, UTF8_CHAR, SIGMA
  c-api.zig           # stable C ABI exports (handle table + mutex)
  lib.zig             # module root
  ops/
    compose.zig       # epsilon-sequencing filter composition
    determinize.zig   # subset construction
    minimize.zig      # Hopcroft partition refinement
    rm-epsilon.zig    # epsilon closure + redirect
    shortest-path.zig # n-best paths
    union.zig         # FST union
    concat.zig        # FST concatenation
    closure.zig       # Kleene star/plus/optional + repeat
    invert.zig        # swap input/output labels
    project.zig       # project to one tape
    difference.zig    # complement + compose
    replace.zig       # recursive substitution + cycle detection
    reverse.zig       # reverse path directions
    rewrite.zig       # context-dependent rewrite (Mohri & Sproat)
    optimize.zig      # rmEpsilon → determinize → minimize pipeline
  io/
    text.zig          # OpenFst AT&T text format
    binary.zig        # mmap-friendly binary snapshot
include/
  fst.h               # C header (u32 handles, not pointers)
tests/
  gen_golden.py       # Pynini golden output generator
  diff/               # differential tests vs golden corpus
  prop/               # property-based tests
  fuzz/               # fuzz test harness
  corpus/             # AT&T text golden files (generated)
references/
  zig-memory-management.md  # Zig memory patterns & pitfalls reference
build.zig             # Zig 0.15 build configuration
```

## Zig Version

- **Zig 0.15.2** — uses the new `Build.addLibrary` / `Build.createModule` API (not the old `addStaticLibrary`)

## Architecture & Design References

### OpenFST Concepts

Core FST operations to implement:
- **Compose** — combine two FSTs (key operation for text normalization pipelines)
- **ShortestPath** — find best path through weighted FST
- **Union / Concat / Closure** — regular expression-like FST construction
- **Determinize / Minimize** — optimize FST for compact representation
- **Arc types** — StdArc (tropical semiring), LogArc (log semiring)

### WeTextProcessing Runtime Pattern

The C++ runtime uses OpenFST with this pipeline:
1. **Tagger FST** — maps input text to tagged tokens (e.g., `"123" → integer { value: "123" }`)
2. **Token Parser** — parses tagged output into structured tokens
3. **Verbalizer FST** — converts structured tokens back to verbalized text
4. **Compose + ShortestPath** — core operations for FST-based string rewriting

### Key Data Structures

- `StdVectorFst` — mutable FST with vector-based state/arc storage
- `StringCompiler<StdArc>` — compile string to single-path FST
- `StringPrinter<StdArc>` — extract string from single-path FST

## Memory Safety Conventions

See **[references/zig-memory-management.md](references/zig-memory-management.md)** for the full Zig memory management reference (allocator patterns, pitfalls, testing strategies).

Key conventions enforced in this codebase:

- **Arena per algorithm**: All ops (determinize, compose, etc.) use `ArenaAllocator` for temporaries. Result FST uses the caller's allocator. Temps are bulk-freed on return.
- **Generation counter**: `MutableFst.generation` increments on every mutation. Use `gen()` / `checkGeneration()` to detect stale arc slices in debug builds.
- **Handle table for C API**: `c-api.zig` uses `HandleTable(T)` with `u32` indices and `std.Thread.Mutex`. C consumers never touch raw pointers. Prevents double-free, use-after-free, type confusion. Thread-safe for concurrent calls.
- **Two-phase model**: Build with `MutableFst` (single-owner, mutable), freeze into `Fst` (immutable, contiguous, thread-safe). Runtime code only touches `Fst`.

## Coding Conventions

- Modern Zig idioms (0.15+)
- No barrel files
- `kebab-case` file names
- `type` over `interface` equivalent patterns
- Explicit `allocator` parameter passing (Zig convention)
- Test blocks colocated in source files

## Package Manager

- Use `bun` for any JS/TS tooling
- Use `zig build` for Zig compilation
