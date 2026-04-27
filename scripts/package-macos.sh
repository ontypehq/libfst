#!/usr/bin/env bash
set -euo pipefail

OUT_DIR="${1:-dist}"
ARCHES="${ARCHES:-arm64 x86_64}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
stage_dir="$repo_root/.scratch/package-macos"
lib_dir="$stage_dir/lib"
include_dir="$stage_dir/include"

rm -rf "$stage_dir"
mkdir -p "$lib_dir" "$include_dir" "$OUT_DIR"
cp "$repo_root/include/fst.h" "$include_dir/fst.h"

zig_target_for_arch() {
  case "$1" in
    arm64) echo "aarch64-macos" ;;
    x86_64) echo "x86_64-macos" ;;
    *) echo "unsupported arch: $1" >&2; exit 1 ;;
  esac
}

repack_archive() {
  local source_archive="$1"
  local output_archive="$2"
  local temp_dir
  temp_dir="$(mktemp -d)"
  (cd "$temp_dir" && ar -x "$source_archive")
  object_names=()
  while IFS= read -r object_name; do
    object_names+=("$object_name")
  done < <(cd "$temp_dir" && find . -maxdepth 1 -name '*.o' -print | sed 's#^\./##' | sort)
  if [[ "${#object_names[@]}" -eq 0 ]]; then
    echo "No object files found in $source_archive" >&2
    exit 1
  fi
  for object_name in "${object_names[@]}"; do
    chmod 600 "$temp_dir/$object_name"
  done
  (cd "$temp_dir" && libtool -static -o "$output_archive" "${object_names[@]}")
  ranlib "$output_archive"
  rm -rf "$temp_dir"
}

validate_link() {
  local arch="$1"
  local archive="$2"
  local temp_dir
  temp_dir="$(mktemp -d)"
  cat > "$temp_dir/main.c" <<'C'
extern unsigned int fst_load(const char* path);
int main(void) { return (int)fst_load(0); }
C
  xcrun --sdk macosx clang -arch "$([[ "$arch" == "arm64" ]] && echo arm64 || echo x86_64)" "$temp_dir/main.c" "$archive" -o "$temp_dir/test_linked"
  rm -rf "$temp_dir"
}

manifest_entries=()
for arch in $ARCHES; do
  target="$(zig_target_for_arch "$arch")"
  (cd "$repo_root" && zig build -Dtarget="$target" -Doptimize=ReleaseFast)
  repack_archive "$repo_root/zig-out/lib/libfst.a" "$lib_dir/libfst-$arch.a"
  validate_link "$arch" "$lib_dir/libfst-$arch.a"
  rm -f "$repo_root/zig-out/lib/libfst.a"

  bytes="$(wc -c < "$lib_dir/libfst-$arch.a" | tr -d ' ')"
  sha256="$(shasum -a 256 "$lib_dir/libfst-$arch.a" | awk '{print $1}')"
  manifest_entries+=("{\"kind\":\"static\",\"arch\":\"$arch\",\"path\":\"lib/libfst-$arch.a\",\"sha256\":\"$sha256\",\"bytes\":$bytes}")
done

(cd "$repo_root" && zig build -Dlinkage=dynamic -Doptimize=ReleaseFast)
cp "$repo_root/zig-out/lib/libfst.dylib" "$lib_dir/libfst-arm64.dylib"
dynamic_bytes="$(wc -c < "$lib_dir/libfst-arm64.dylib" | tr -d ' ')"
dynamic_sha="$(shasum -a 256 "$lib_dir/libfst-arm64.dylib" | awk '{print $1}')"
manifest_entries+=("{\"kind\":\"dynamic\",\"arch\":\"arm64\",\"path\":\"lib/libfst-arm64.dylib\",\"sha256\":\"$dynamic_sha\",\"bytes\":$dynamic_bytes}")

entries_json="$(IFS=,; echo "${manifest_entries[*]}")"
cat > "$stage_dir/manifest.json" <<JSON
{
  "version": 1,
  "artifact": "libfst-macos",
  "sourceRevision": "$(git -C "$repo_root" rev-parse HEAD)",
  "zigVersion": "$(zig version)",
  "xcodeVersion": "$(xcodebuild -version | tr '\n' ' ' | sed 's/[[:space:]]*$//')",
  "builtAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "files": [$entries_json]
}
JSON

tag_name="$(git -C "$repo_root" describe --tags --exact-match 2>/dev/null || git -C "$repo_root" rev-parse --short=12 HEAD)"
artifact_name="libfst-macos-$tag_name.tar.gz"
tar -czf "$OUT_DIR/$artifact_name" -C "$stage_dir" lib include manifest.json
shasum -a 256 "$OUT_DIR/$artifact_name" > "$OUT_DIR/$artifact_name.sha256"

echo "artifact=$OUT_DIR/$artifact_name"
