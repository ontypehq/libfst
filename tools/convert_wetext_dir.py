#!/usr/bin/env python3
"""
Batch-convert WeText/OpenFst .fst files into libfst binary format.

Example:
  python3 tools/convert_wetext_dir.py \
    --input-dir /path/to/wetext/itn \
    --output-dir /path/to/out
"""

from __future__ import annotations

import argparse
import subprocess
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Batch convert WeText/OpenFst .fst to libfst format."
    )
    parser.add_argument(
        "--input-dir",
        required=True,
        type=Path,
        help="Directory containing WeText/OpenFst .fst files.",
    )
    parser.add_argument(
        "--output-dir",
        required=True,
        type=Path,
        help="Directory to write converted .libfst.fst files.",
    )
    parser.add_argument(
        "--suffix",
        default=".libfst.fst",
        help="Output suffix appended after stripping .fst (default: .libfst.fst).",
    )
    parser.add_argument(
        "--include",
        nargs="*",
        default=("*_tagger.fst", "*_verbalizer.fst"),
        help="Glob patterns to include (default: *_tagger.fst *_verbalizer.fst).",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print planned conversions without executing.",
    )
    return parser.parse_args()


def collect_inputs(input_dir: Path, patterns: list[str]) -> list[Path]:
    files: list[Path] = []
    for pattern in patterns:
        files.extend(input_dir.glob(pattern))
    # de-duplicate and stable order
    return sorted(set(f for f in files if f.is_file()))


def main() -> int:
    args = parse_args()

    input_dir = args.input_dir.resolve()
    output_dir = args.output_dir.resolve()
    converter = (Path(__file__).resolve().parent / "convert_wetext_fst.sh").resolve()

    if not input_dir.is_dir():
        print(f"error: input dir not found: {input_dir}")
        return 1
    if not converter.is_file():
        print(f"error: converter script not found: {converter}")
        return 1

    candidates = collect_inputs(input_dir, list(args.include))
    if not candidates:
        print(f"no matching files in {input_dir}")
        return 0

    output_dir.mkdir(parents=True, exist_ok=True)
    print(f"found {len(candidates)} file(s)")

    for src in candidates:
        stem = src.name[:-4] if src.name.endswith(".fst") else src.name
        dst = output_dir / f"{stem}{args.suffix}"
        print(f"{src} -> {dst}")
        if args.dry_run:
            continue
        subprocess.run(
            [str(converter), str(src), str(dst)],
            check=True,
        )

    print("done")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
