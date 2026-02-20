#!/usr/bin/env python3
"""Run issue #1 benchmark matrix for compose_frozen workloads.

Usage:
  python3 bench/run_issue1_bench.py
  python3 bench/run_issue1_bench.py --lengths 5,10,20,30,40,50 --transducer-len 2048
"""

from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path


SCENARIOS = (
    "compose_frozen_transducer",
    "compose_frozen_shortest_path",
)


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Run compose_frozen benchmark matrix.")
    p.add_argument("--lengths", default="5,10,20,30,40,50", help="Comma-separated input lengths.")
    p.add_argument("--transducer-len", type=int, default=2048, help="Synthetic transducer length.")
    p.add_argument("--branches", type=int, default=6, help="Branching factor for synthetic transducer.")
    p.add_argument("--iters", type=int, default=50, help="Timed iterations.")
    p.add_argument("--warmup", type=int, default=10, help="Warmup iterations.")
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
    lengths = [int(x) for x in args.lengths.split(",") if x.strip()]
    repo = Path(__file__).resolve().parents[1]

    rows = []
    for scenario in SCENARIOS:
        for length in lengths:
            rows.append(run_one(repo, scenario, length, args))

    print(
        "| scenario | len | transducer_len | branches | avg_us | min_us | max_us | avg_states |",
    )
    print("|---|---:|---:|---:|---:|---:|---:|---:|")
    for row in rows:
        avg_us = row["avg_ns"] / 1000.0
        min_us = row["min_ns"] / 1000.0
        max_us = row["max_ns"] / 1000.0
        print(
            f"| {row['scenario']} | {row['len']} | {row['transducer_len']} | {row['branches']} | "
            f"{avg_us:.3f} | {min_us:.3f} | {max_us:.3f} | {row['avg_states']} |",
        )

    print("\n# jsonl")
    for row in rows:
        print(json.dumps(row, ensure_ascii=True))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

