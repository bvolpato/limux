#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
# Exercise the production polling functions without launching the GUI.
# shellcheck disable=SC1090
source <(sed -n '/^host_child_count() {$/,/^}$/p; /^wait_for_host_child_count() {$/,/^}$/p' \
  "$ROOT_DIR/scripts/xvfb-smoke-test.sh")

TEST_DIR="$(mktemp -d -t limux-child-count-XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
HOST_PID=$$

sleep() { :; }
awk() {
  case "$SCENARIO" in
    partial)
      printf '0\n'
      echo 'awk: children file disappeared' >&2
      return 2
      ;;
    transient)
      if [ ! -e "$TEST_DIR/retried" ]; then
        touch "$TEST_DIR/retried"
        # Simulate a thread disappearing after its children path was expanded.
        command awk "$1" "$TEST_DIR/disappeared/children"
        return $?
      fi
      printf '2\n'
      ;;
    mismatch) printf '3\n' ;;
    zero) printf '0\n' ;;
  esac
}

SCENARIO=partial
if host_child_count >"$TEST_DIR/count" 2>"$TEST_DIR/error"; then
  echo 'FAIL: accepted an incomplete child-count sample' >&2
  exit 1
fi
if [ -s "$TEST_DIR/count" ] || [ -s "$TEST_DIR/error" ]; then
  echo 'FAIL: incomplete scan leaked a partial count or warning' >&2
  exit 1
fi
for expected in '' 0; do
  if wait_for_host_child_count "$expected" >"$TEST_DIR/count" 2>"$TEST_DIR/error"; then
    echo 'FAIL: persistent read failure passed as a baseline or zero count' >&2
    exit 1
  fi
  [ ! -s "$TEST_DIR/count" ]
  grep -Fq "host $HOST_PID" "$TEST_DIR/error"
  grep -Fq 'unavailable' "$TEST_DIR/error"
done

SCENARIO=transient
wait_for_host_child_count >"$TEST_DIR/count" 2>"$TEST_DIR/error"
[ "$(<"$TEST_DIR/count")" = 2 ]
[ ! -s "$TEST_DIR/error" ]
rm "$TEST_DIR/retried"
wait_for_host_child_count 2 >"$TEST_DIR/count" 2>"$TEST_DIR/error"
[ ! -s "$TEST_DIR/count" ] && [ ! -s "$TEST_DIR/error" ]

SCENARIO=mismatch
if wait_for_host_child_count 2 >"$TEST_DIR/count" 2>"$TEST_DIR/error"; then
  echo 'FAIL: a complete but incorrect child count passed' >&2
  exit 1
fi
grep -Fq 'last complete=3, expected=2' "$TEST_DIR/error"

SCENARIO=zero
[ "$(wait_for_host_child_count)" = 0 ]
wait_for_host_child_count 0

echo 'smoke child-count polling regression checks passed'
