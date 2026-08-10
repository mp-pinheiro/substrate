#!/usr/bin/env bash
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$TEST_DIR/lib"
KIT_ROOT="$(cd "$TEST_DIR/.." && pwd)"
export KIT_ROOT

source "$LIB_DIR/engine-fixture.sh"

TMPDIR="${TMPDIR:-/tmp}"
WORK=$(mktemp -d "$TMPDIR/gate-rollback.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

fail_fn() {
    printf '  [XX] %s\n' "$1" >&2
    fail=$((fail + 1))
}

engine_bin=$(engine_build fail_fn "gate-rollback") || exit 2

printf 'gate-rollback: go-only gate invocation\n'

out="$WORK/gate-out.txt"
"$engine_bin" gate > "$out" 2>&1
rc=$?
cat "$out"

if [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]; then
    printf '  [ok] gate runs natively (rc=%d)\n' "$rc"
    pass=$((pass + 1))
else
    fail_fn "gate unexpected exit code: $rc"
fi

if [ "$fail" -gt 0 ]; then
    printf 'gate-rollback: %d scenarios green, %d failed\n' "$pass" "$fail"
    exit 1
fi
printf 'gate-rollback: %d scenarios green\n' "$pass"
exit 0
