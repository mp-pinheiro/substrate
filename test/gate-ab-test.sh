#!/usr/bin/env bash
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$TEST_DIR/lib"
KIT_ROOT="$(cd "$TEST_DIR/.." && pwd)"
export KIT_ROOT

source "$LIB_DIR/engine-fixture.sh"

TMPDIR="${TMPDIR:-/tmp}"
WORK=$(mktemp -d "$TMPDIR/gate-ab.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

fail_fn() {
    printf '  [XX] %s\n' "$1" >&2
    fail=$((fail + 1))
}

engine=$(engine_build fail_fn "gate-ab-test") || exit 2

printf 'gate-ab: go-only gate verification\n'

out="$WORK/gate-out.txt"
"$engine" gate > "$out" 2>&1
rc=$?
cat "$out"

if [ "$rc" -eq 0 ]; then
    printf '  [ok] gate green (exit %d)\n' "$rc"
    pass=$((pass + 1))
else
    fail_fn "gate expected exit 0 (green), got $rc"
fi

if [ "$fail" -gt 0 ]; then
    printf 'gate-ab: %d scenarios green, %d failed\n' "$pass" "$fail"
    exit 1
fi
printf 'gate-ab: %d scenarios green\n' "$pass"
exit 0
