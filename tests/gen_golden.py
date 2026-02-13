#!/usr/bin/env python3
"""Generate golden AT&T text outputs using Pynini for diff testing.

Requires: pip install pynini

Each test case generates:
  tests/corpus/{test_name}.input.att   — input FST(s)
  tests/corpus/{test_name}.golden.att  — expected output FST

Usage:
  python tests/gen_golden.py
"""

import os
import sys

try:
    import pynini
    from pynini.lib import rewrite as rw
except ImportError:
    print("ERROR: pynini not installed. Install with: pip install pynini", file=sys.stderr)
    sys.exit(1)

CORPUS_DIR = os.path.join(os.path.dirname(__file__), "corpus")
os.makedirs(CORPUS_DIR, exist_ok=True)


def write_fst(fst, path):
    """Write FST in AT&T text format."""
    fst.write(path)


def write_text(fst, path):
    """Write FST as AT&T text to a file."""
    text = fst.print()
    with open(path, "w") as f:
        f.write(text)
        f.write("\n")


def make_sigma_star(labels=range(1, 128)):
    """Build sigma* over the given label range."""
    syms = pynini.SymbolTable()
    syms.add_symbol("<eps>", 0)
    for l in labels:
        syms.add_symbol(chr(l), l)
    sigma = pynini.union(*[pynini.accep(chr(l)) for l in labels])
    return pynini.closure(sigma)


# ── Test case generators ──


def gen_compose():
    """compose: a->b ∘ b->c = a->c"""
    fst1 = pynini.cross("a", "b")
    fst2 = pynini.cross("b", "c")
    result = pynini.compose(fst1, fst2).optimize()

    write_text(fst1, os.path.join(CORPUS_DIR, "compose.input1.att"))
    write_text(fst2, os.path.join(CORPUS_DIR, "compose.input2.att"))
    write_text(result, os.path.join(CORPUS_DIR, "compose.golden.att"))


def gen_determinize():
    """determinize: NFA -> DFA"""
    # NFA: two paths for "a" with different weights
    fst = pynini.union(
        pynini.accep("a", weight=1.0),
        pynini.accep("a", weight=2.0),
    )
    result = pynini.determinize(fst).optimize()

    write_text(fst, os.path.join(CORPUS_DIR, "determinize.input.att"))
    write_text(result, os.path.join(CORPUS_DIR, "determinize.golden.att"))


def gen_union():
    """union: a | b"""
    fst1 = pynini.accep("a")
    fst2 = pynini.accep("b")
    result = pynini.union(fst1, fst2).optimize()

    write_text(fst1, os.path.join(CORPUS_DIR, "union.input1.att"))
    write_text(fst2, os.path.join(CORPUS_DIR, "union.input2.att"))
    write_text(result, os.path.join(CORPUS_DIR, "union.golden.att"))


def gen_concat():
    """concat: a · b = ab"""
    fst1 = pynini.accep("a")
    fst2 = pynini.accep("b")
    result = pynini.concat(fst1, fst2).optimize()

    write_text(fst1, os.path.join(CORPUS_DIR, "concat.input1.att"))
    write_text(fst2, os.path.join(CORPUS_DIR, "concat.input2.att"))
    write_text(result, os.path.join(CORPUS_DIR, "concat.golden.att"))


def gen_closure():
    """closure: a* (Kleene star)"""
    fst = pynini.accep("a")
    result = pynini.closure(fst).optimize()

    write_text(fst, os.path.join(CORPUS_DIR, "closure_star.input.att"))
    write_text(result, os.path.join(CORPUS_DIR, "closure_star.golden.att"))


def gen_invert():
    """invert: swap input/output labels"""
    fst = pynini.cross("a", "b")
    result = pynini.invert(fst).optimize()

    write_text(fst, os.path.join(CORPUS_DIR, "invert.input.att"))
    write_text(result, os.path.join(CORPUS_DIR, "invert.golden.att"))


def gen_project():
    """project: extract input/output tape"""
    fst = pynini.cross("a", "b")
    result_in = pynini.project(fst, "input").optimize()
    result_out = pynini.project(fst, "output").optimize()

    write_text(fst, os.path.join(CORPUS_DIR, "project.input.att"))
    write_text(result_in, os.path.join(CORPUS_DIR, "project_input.golden.att"))
    write_text(result_out, os.path.join(CORPUS_DIR, "project_output.golden.att"))


def gen_cdrewrite():
    """cdrewrite: a -> b / everywhere"""
    sigma_star = make_sigma_star(range(ord("a"), ord("z") + 1))
    tau = pynini.cross("a", "b")
    # Empty contexts
    lambda_ctx = pynini.accep("")
    rho_ctx = pynini.accep("")

    result = pynini.cdrewrite(tau, lambda_ctx, rho_ctx, sigma_star).optimize()

    write_text(result, os.path.join(CORPUS_DIR, "cdrewrite_simple.golden.att"))


def gen_cdrewrite_context():
    """cdrewrite: a -> b / c _ d"""
    sigma_star = make_sigma_star(range(ord("a"), ord("z") + 1))
    tau = pynini.cross("a", "b")
    lambda_ctx = pynini.accep("c")
    rho_ctx = pynini.accep("d")

    result = pynini.cdrewrite(tau, lambda_ctx, rho_ctx, sigma_star).optimize()

    write_text(result, os.path.join(CORPUS_DIR, "cdrewrite_context.golden.att"))


def gen_shortest_path():
    """shortest_path: find n-best paths"""
    fst = pynini.union(
        pynini.accep("a", weight=1.0),
        pynini.accep("b", weight=2.0),
        pynini.accep("c", weight=0.5),
    )
    result = pynini.shortestpath(fst, nshortest=2)

    write_text(fst, os.path.join(CORPUS_DIR, "shortest_path.input.att"))
    write_text(result, os.path.join(CORPUS_DIR, "shortest_path.golden.att"))


def gen_difference():
    """difference: {a, b} - {a} = {b}"""
    fst1 = pynini.union(pynini.accep("a"), pynini.accep("b"))
    fst2 = pynini.accep("a")
    result = pynini.difference(fst1, fst2).optimize()

    write_text(fst1, os.path.join(CORPUS_DIR, "difference.input1.att"))
    write_text(fst2, os.path.join(CORPUS_DIR, "difference.input2.att"))
    write_text(result, os.path.join(CORPUS_DIR, "difference.golden.att"))


def gen_optimize():
    """optimize: rmeps + det + min pipeline"""
    # Build an FST with epsilon transitions and nondeterminism
    fst = pynini.union(
        pynini.accep("ab", weight=1.0),
        pynini.accep("ab", weight=2.0),
    )
    # Add epsilon path
    eps_fst = pynini.Fst()
    s0 = eps_fst.add_state()
    s1 = eps_fst.add_state()
    s2 = eps_fst.add_state()
    eps_fst.set_start(s0)
    eps_fst.set_final(s2)
    eps_fst.add_arc(s0, pynini.Arc(0, 0, 0, s1))  # epsilon
    eps_fst.add_arc(s1, pynini.Arc(ord("a") + 1, ord("a") + 1, 0, s2))

    combined = pynini.union(fst, eps_fst)
    result = combined.optimize()

    write_text(combined, os.path.join(CORPUS_DIR, "optimize.input.att"))
    write_text(result, os.path.join(CORPUS_DIR, "optimize.golden.att"))


# ── Main ──

GENERATORS = [
    ("compose", gen_compose),
    ("determinize", gen_determinize),
    ("union", gen_union),
    ("concat", gen_concat),
    ("closure", gen_closure),
    ("invert", gen_invert),
    ("project", gen_project),
    ("cdrewrite_simple", gen_cdrewrite),
    ("cdrewrite_context", gen_cdrewrite_context),
    ("shortest_path", gen_shortest_path),
    ("difference", gen_difference),
    ("optimize", gen_optimize),
]


def main():
    print(f"Generating golden outputs in {CORPUS_DIR}/")
    for name, gen_fn in GENERATORS:
        try:
            gen_fn()
            print(f"  ✓ {name}")
        except Exception as e:
            print(f"  ✗ {name}: {e}", file=sys.stderr)
    print("Done.")


if __name__ == "__main__":
    main()
