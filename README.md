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
| `compose_shortest_path` | Lazy shortest path on implicit compose graph (`n=1`) |
| `determinize` | Convert acceptor NFA to DFA (acceptor-only) |
| `minimize` | Merge equivalent states (Hopcroft partition refinement) |
| `rm_epsilon` | Remove epsilon transitions |
| `shortest_path` | Find single best path (`n=1`) |
| `union` | L(a) ∪ L(b) |
| `concat` | L(a) · L(b) |
| `closure` | L* (star), L+ (plus), L? (optional) |
| `invert` | Swap input/output tapes |
| `project` | Project to input or output tape |
| `difference` | L(a) - L(b), with deterministic epsilon-free unweighted RHS |
| `replace` | Recursive subroutine substitution with cycle detection |
| `cdrewrite` | Context-dependent obligatory rewrite (unit-weight grammars) |
| `reverse` | Reverse all paths |
| `optimize` | Pipeline: rmEpsilon → determinize → minimize → connect |

## Thread Safety

Handle table bookkeeping is mutex-protected, but heavy algorithms run on
snapshots outside the lock. This removes full-call serialization for
compute-heavy C API operations.

`fst_compose_frozen` pins immutable handles for lock-free composition
instead of cloning frozen bytes on every call.
`fst_compose_frozen_shortest_path` additionally avoids materializing the
full compose lattice for best-path extraction.

In-place mutating C APIs (`union`/`concat`/`closure`/`minimize`) use optimistic
commit and return `invalid_arg` if the same handle changed concurrently.

`MutableFst`: single-writer. `Fst` (frozen): fully reentrant and thread-safe.

## Build & Test

```bash
zig build              # static library + C header
zig build test         # unit tests
zig build prop         # property-based tests (semiring laws, idempotency)
zig build fuzz         # fuzz test harness
zig build diff         # diff tests vs Pynini golden outputs (needs corpus)
zig build att2lfst     # build converter at zig-out/bin/att2lfst
zig build bench        # run profile-friendly benchmark (scenarios + JSON output)
```

Example benchmark run:

```bash
zig build bench -Doptimize=ReleaseFast -- \
  --scenario compose_frozen_epsilon_dense \
  --len 96 --transducer-len 4096 --branches 12 \
  --iters 200 --warmup 30 \
  --format json
```

Issue #1 matrix benchmark:

```bash
python3 bench/run_issue1_bench.py \
  --lengths 5,10,20,30,40,50 \
  --transducer-len 2048 \
  --branches 6 \
  --iters 100 --warmup 20
```

Issue #1 profile-friendly stress benchmark:

```bash
python3 bench/run_issue1_profile_bench.py \
  --lengths 11,19,33,64,96,128,160,192,224,251 \
  --transducer-len 4096 \
  --branches 12 \
  --iters 120 --warmup 20
```

Default stress matrix includes:
- `compose_frozen_epsilon_dense` (epsilon-heavy topology)
- `compose_frozen_ambiguous_chain` (nondeterministic repeated-label topology)
- `compose_frozen_shortest_path_ambiguous` (eager compose + shortest_path)
- `compose_frozen_lazy_shortest_path_ambiguous` (lazy compose_shortest_path)
- `compose_frozen_shortest_path_epsilon_dense` (eager compose + shortest_path)
- `compose_frozen_lazy_shortest_path_epsilon_dense` (lazy compose_shortest_path)

Legacy example:

```bash
zig build bench -Doptimize=ReleaseFast -- \
  --scenario optimize_transducer \
  --len 16384 --branches 4 \
  --iters 300 --warmup 20 \
  --format json
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

## WeTextProcessing Conversion

For OnType integration, a pragmatic path is:
1. Keep WeText/OpenFst assets as source of truth (`*_tagger.fst`, `*_verbalizer.fst`)
2. Either load OpenFst `.fst` directly via `fst_load_openfst` (requires `fstprint`), or
   convert them offline into libfst binary format for deployment simplicity

### Option A: one-shot converter script

```bash
tools/convert_wetext_fst.sh zh_itn_tagger.fst zh_itn_tagger.libfst.fst
tools/convert_wetext_fst.sh zh_itn_verbalizer.fst zh_itn_verbalizer.libfst.fst
```

Requires `fstprint` (OpenFst CLI) and `zig`.

### Option A2: batch convert a directory (Python)

```bash
python3 tools/convert_wetext_dir.py \
  --input-dir /path/to/wetext/itn \
  --output-dir /path/to/libfst-assets
```

By default it converts `*_tagger.fst` and `*_verbalizer.fst`.

### Option B: explicit two-step conversion

```bash
fstprint zh_itn_tagger.fst > /tmp/zh_itn_tagger.att
zig build att2lfst
./zig-out/bin/att2lfst --input /tmp/zh_itn_tagger.att --output zh_itn_tagger.libfst.fst
```

### Runtime direct loading

- `fst_load(path)`: libfst native binary only.
- `fst_load_openfst(path)`: OpenFst `.fst` via `fstprint` + AT&T import.

## License

MIT
