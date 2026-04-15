# libfst

Finite State Transducer library in Zig, inspired by
[OpenFST](https://www.openfst.org/) and
[WeTextProcessing](https://github.com/wenet-e2e/WeTextProcessing).

## Skills First

- This repository is configured with `$zig` and `$zigdoc`.
- For Zig syntax, standard-library APIs, build-system details, migration
  questions, or code-review checks, load the relevant skill instead of copying
  guidance into this file.
- Use `zigdoc` for exact signatures before changing Zig std APIs. Zig changes
  too fast for memory-based edits to be acceptable.
- Keep this file limited to libfst-specific architecture, commands, and known
  project constraints.

## Build & Test

```bash
zig build              # build static library, C header, tools, benchmark
zig build test         # unit tests
zig build prop         # property tests
zig build fuzz         # fuzz harness
zig build diff         # differential tests vs corpus
zig build att2lfst     # build converter at zig-out/bin/att2lfst
zig build bench        # run benchmark
```

Known gap: `zig build diff` includes a shortest-path corpus that expects `n=2`,
while `src/ops/shortest-path.zig` intentionally supports only `n == 1`.
Do not paper over this by pretending n-best exists; either implement real
n-shortest paths or regenerate/retire that corpus case.

## Project Map

```text
src/
  weight.zig          # TropicalWeight, LogWeight
  arc.zig             # Arc(W), Label, StateId
  sym.zig             # SymbolTable
  mutable-fst.zig     # build-time mutable graph
  fst.zig             # frozen contiguous graph
  string.zig          # compileString / printString
  char-class.zig      # byte and UTF-8 character classes
  c-api.zig           # stable C ABI handle table
  lib.zig             # module root
  io/
    text.zig          # OpenFst AT&T text format
    binary.zig        # native binary snapshot
  ops/
    compose.zig
    compose-shortest-path.zig
    connect.zig
    determinize.zig
    minimize.zig
    rm-epsilon.zig
    shortest-path.zig
    union.zig
    concat.zig
    closure.zig
    invert.zig
    project.zig
    difference.zig
    replace.zig
    reverse.zig
    rewrite.zig
    optimize.zig
  tools/
    att2lfst.zig
include/
  fst.h
tests/
  prop/
  fuzz/
  diff/
  corpus/
```

## Architecture Rules

- Keep the core algorithms pure with explicit allocator/data inputs. File I/O,
  process spawning, environment reads, and clocks belong at the edge.
- Validate external data at the boundary, then convert into `MutableFst` or
  `Fst` before running algorithms.
- Prefer small transformation functions over long flows that mix parsing,
  mutation, and algorithmic decisions.
- Make expected failures explicit in return errors. Do not silently coerce an
  unsupported operation into a partial result.

## Memory & Thread Safety

- Operations use an arena for temporaries and return results allocated by the
  caller's allocator.
- `MutableFst` is single-owner mutable state.
- `Fst` is immutable, contiguous, and safe for concurrent reads.
- C consumers receive `u32` handles, never raw pointers.
- The C API handle table uses generation and pin counts to avoid use-after-free
  while allowing heavy algorithms to run outside the global table lock.

## Conventions

- File names are `kebab-case`.
- Test blocks stay near the code they cover unless they need a separate corpus.
- Comments should explain non-obvious trade-offs or invariants, not restate the
  line of code.
- If a workaround or unsupported case remains, add it to `.agents/backlog.md`
  with a short note before finishing the change.
