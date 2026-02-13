#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  tools/convert_wetext_fst.sh <input_openfst.fst> <output_libfst.fst>

Description:
  Converts a WeTextProcessing/OpenFst binary .fst file into libfst binary format.

Requirements:
  - fstprint (OpenFst CLI)
  - zig (to run the att2lfst converter)
EOF
}

if [[ $# -ne 2 ]]; then
  usage
  exit 2
fi

if ! command -v fstprint >/dev/null 2>&1; then
  echo "error: 'fstprint' not found in PATH. Install OpenFst CLI tools first." >&2
  exit 1
fi

if ! command -v zig >/dev/null 2>&1; then
  echo "error: 'zig' not found in PATH." >&2
  exit 1
fi

input_fst="$1"
output_fst="$2"

if [[ ! -f "$input_fst" ]]; then
  echo "error: input file not found: $input_fst" >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_att="$(mktemp "${TMPDIR:-/tmp}/wetext-XXXXXX.att")"
trap 'rm -f "$tmp_att"' EXIT

fstprint "$input_fst" > "$tmp_att"

zig build --build-file "$repo_root/build.zig" att2lfst
"$repo_root/zig-out/bin/att2lfst" \
  --input "$tmp_att" \
  --output "$output_fst"

echo "converted: $input_fst -> $output_fst"
