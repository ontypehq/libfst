#!/usr/bin/env python3
"""Run a profile-friendly matrix for issue #1 long-input compose behavior.

This script emphasizes epsilon-dense workloads that are more likely to expose
super-linear growth than the basic synthetic transducer.
"""

from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Run profile-friendly issue #1 benchmark matrix.")
    p.add_argument(
        "--scenarios",
        default="compose_frozen_transducer,compose_frozen_epsilon_dense,compose_frozen_ambiguous_chain,compose_frozen_shortest_path_ambiguous,compose_frozen_lazy_shortest_path_ambiguous,compose_frozen_shortest_path_epsilon_dense,compose_frozen_lazy_shortest_path_epsilon_dense",
        help="Comma-separated scenario names.",
    )
    p.add_argument(
        "--lengths",
        default="11,19,33,64,96,128,160,192,224,251",
        help="Comma-separated input lengths.",
    )
    p.add_argument("--transducer-len", type=int, default=4096, help="Synthetic transducer length.")
    p.add_argument("--branches", type=int, default=12, help="Branching factor.")
    p.add_argument("--iters", type=int, default=120, help="Timed iterations.")
    p.add_argument("--warmup", type=int, default=20, help="Warmup iterations.")
    p.add_argument("--optimize", default="ReleaseFast", help="zig -Doptimize mode.")
    return p.parse_args()


def run_one(repo: Path, scenario: str, length: int, args: argparse.Namespace) -> dict:
    cmd = [
        "zig",
        "build",
        "bench",
        f"-Doptimize={args.optimize}",
        "--",
        "--scenario",
        scenario,
        "--len",
        str(length),
        "--transducer-len",
        str(args.transducer_len),
        "--branches",
        str(args.branches),
        "--iters",
        str(args.iters),
        "--warmup",
        str(args.warmup),
        "--format",
        "json",
    ]
    out = subprocess.check_output(cmd, cwd=repo, text=True)
    return json.loads(out.strip())


def main() -> int:
    args = parse_args()
    repo = Path(__file__).resolve().parents[1]
    lengths = [int(x) for x in args.lengths.split(",") if x.strip()]
    scenarios = [x.strip() for x in args.scenarios.split(",") if x.strip()]

    rows = []
    for scenario in scenarios:
        for length in lengths:
            rows.append(run_one(repo, scenario, length, args))

    print("| scenario | len | transducer_len | branches | avg_us | min_us | max_us | avg_states |")
    print("|---|---:|---:|---:|---:|---:|---:|---:|")
    for row in rows:
        print(
            f"| {row['scenario']} | {row['len']} | {row['transducer_len']} | {row['branches']} | "
            f"{row['avg_ns'] / 1000.0:.3f} | {row['min_ns'] / 1000.0:.3f} | "
            f"{row['max_ns'] / 1000.0:.3f} | {row['avg_states']} |",
        )

    print("\n# jsonl")
    for row in rows:
        print(json.dumps(row, ensure_ascii=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
