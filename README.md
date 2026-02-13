# libfst

Zig implementation of Weighted Finite State Transducers, semantically aligned
with [OpenFst](https://www.openfst.org/)/[Pynini](https://www.openfst.org/twiki/bin/view/GRM/Pynini). Stable C ABI for Swift/Rust/C++ integration.

## Quick Start (Zig)

```zig
const libfst = @import("libfst");
const W = libfst.TropicalWeight;
const MutableFst = libfst.MutableFst(W);
const Fst = libfst.Fst(W);
const A = libfst.Arc(W);

var fst = MutableFst.init(allocator);
defer fst.deinit();

const s0 = try fst.addState();
const s1 = try fst.addState();
fst.setStart(s0);
fst.setFinal(s1, W.one);
try fst.addArc(s0, A.init('a' + 1, 'b' + 1, W.one, s1));

// Freeze for runtime (contiguous, thread-safe, mmap-friendly)
var frozen = try Fst.fromMutable(allocator, &fst);
defer frozen.deinit();
```

## Quick Start (C)

```c
#include <fst.h>

FstMutableHandle h = fst_mutable_new();
uint32_t s0 = fst_mutable_add_state(h);
uint32_t s1 = fst_mutable_add_state(h);
fst_mutable_set_start(h, s0);
fst_mutable_set_final(h, s1, 0.0);
fst_mutable_add_arc(h, s0, 'a'+1, 'b'+1, 0.0, s1);

FstHandle frozen = fst_freeze(h);
// ... query frozen FST ...
fst_free(frozen);
fst_mutable_free(h);
```

## Operations

| Operation | Description |
|-----------|-------------|
| `compose` | Combine two FSTs (key operation for text normalization) |
| `determinize` | Convert NFA to DFA |
| `minimize` | Merge equivalent states (Hopcroft partition refinement) |
| `rm_epsilon` | Remove epsilon transitions |
| `shortest_path` | Find n-best paths |
| `union` | L(a) ∪ L(b) |
| `concat` | L(a) · L(b) |
| `closure` | L* (star), L+ (plus), L? (optional) |
| `invert` | Swap input/output tapes |
| `project` | Project to input or output tape |
| `difference` | L(a) - L(b) |
| `replace` | Recursive subroutine substitution with cycle detection |
| `cdrewrite` | Context-dependent obligatory rewrite (unit-weight grammars) |
| `reverse` | Reverse all paths |
| `optimize` | Pipeline: rmEpsilon → determinize → minimize → connect |

## Thread Safety

Handle table operations are mutex-protected (safe for concurrent C API calls).
`MutableFst`: single-writer. `Fst` (frozen): fully reentrant and thread-safe.

## Build & Test

```bash
zig build              # static library + C header
zig build test         # unit tests
zig build prop         # property-based tests (semiring laws, idempotency)
zig build fuzz         # fuzz test harness
zig build diff         # diff tests vs Pynini golden outputs (needs corpus)
```

To generate golden corpus for diff tests:

```bash
pip install pynini
python tests/gen_golden.py
zig build diff
```

## Architecture

Two-phase model:
- **`MutableFst(W)`** — build-time mutable FST, all operations work on this
- **`Fst(W)`** — frozen immutable FST, contiguous memory layout, thread-safe queries

Weight types: `TropicalWeight` (min/+), `LogWeight` (log-add/+) — both f64 semirings.

Labels: `u32` (0 = epsilon). StateId: `u32` (maxInt = no_state sentinel).

## Zig Version

**Zig 0.15.2** — uses `Build.addLibrary` / `Build.createModule` API.

## Rewrite Semantics Notes

- `cdrewrite` implements obligatory behavior by composing with the produced rule,
  then taking `shortest_path(n=1)` on projected output.
- To avoid ambiguous weighted preference inversions, `cdrewrite` currently
  **rejects weighted rule/context FSTs** (`tau`, `lambda`, `rho` must be unit-weight).

## License

MIT
