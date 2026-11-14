#!/usr/bin/env bash
# Shared provenance validation for local Ghostty builds. This file may be sourced.
set -euo pipefail

ghostty_build_error() {
  local root="$1"
  shift
  printf 'ERROR: %s\nLibrary: %s/ghostty/zig-out/lib/libghostty-internal.so\n' "$*" "$root" >&2
  printf 'Rebuild from this checkout with Zig 0.16.0: ./scripts/build-ghostty.sh\n' >&2
  return 1
}

ghostty_source_revision() {
  local root="$1" source_root status
  source_root="$(git -C "$root/ghostty" rev-parse --show-toplevel 2>/dev/null)" || {
    ghostty_build_error "$root" 'Ghostty is not initialized; run git submodule update --init --recursive.'
    return 1
  }
  if [ "$source_root" != "$(realpath "$root/ghostty")" ] || [ ! -f "$root/ghostty/build.zig" ]; then
    ghostty_build_error "$root" 'Ghostty is not an initialized Git checkout; run git submodule update --init --recursive.'
    return 1
  fi
  status="$(git -C "$root/ghostty" status --porcelain --untracked-files=normal)" || return 1
  if [ -n "$status" ]; then
    ghostty_build_error "$root" 'Ghostty source has local changes; a commit alone cannot identify this build. Preserve and commit those changes before building.'
    return 1
  fi
  git -C "$root/ghostty" rev-parse HEAD
}

check_ghostty_build() {
  local root="$1" revision library provenance actual_hash actual_path
  local -a record
  library="$root/ghostty/zig-out/lib/libghostty-internal.so"
  provenance="$root/ghostty/zig-out/lib/limux-ghostty-build"
  revision="$(ghostty_source_revision "$root")" || return 1
  if [ ! -f "$library" ]; then
    ghostty_build_error "$root" 'Ghostty shared library is missing.'
    return 1
  fi
  if [ ! -f "$provenance" ]; then
    ghostty_build_error "$root" 'Ghostty build provenance is missing; existing or packaged libraries cannot be verified.'
    return 1
  fi
  mapfile -t record < "$provenance"
  if [ "${#record[@]}" -ne 5 ] || [ "${record[0]}" != limux-ghostty-build-v1 ] || [ "${record[4]}" != zig_version=0.16.0 ]; then
    ghostty_build_error "$root" 'Ghostty build provenance is invalid.'
    return 1
  fi
  if [ "${record[1]}" != "ghostty_commit=$revision" ]; then
    ghostty_build_error "$root" "Ghostty revision mismatch: ${record[1]}; checkout requires $revision."
    return 1
  fi
  actual_path="$(realpath "$library")" || return 1
  if [ "${record[3]}" != "library_realpath=$actual_path" ]; then
    ghostty_build_error "$root" "Ghostty library target changed: ${record[3]}; now resolves to $actual_path."
    return 1
  fi
  actual_hash="$(sha256sum < "$library")" || return 1
  actual_hash="${actual_hash%% *}"
  if [ "${record[2]}" != "library_sha256=$actual_hash" ]; then
    ghostty_build_error "$root" 'Ghostty library checksum changed since its recorded build.'
    return 1
  fi
  printf 'Verified Ghostty %s (%s)\n' "$revision" "$actual_path"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  check_ghostty_build "$(cd "$(dirname "$0")/.." && pwd)"
fi
