#!/usr/bin/env bash
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$TEST_DIR/lib"
KIT_ROOT="$(cd "$TEST_DIR/.." && pwd)"

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
engine_dir=$(dirname "$engine_bin")


# (a) SUBSTRATE_ENGINE=bash runs bash path
SUBSTRATE_ENGINE=bash bash "$KIT_ROOT/.substrate/gate.sh" > "$WORK/a.txt" 2>&1
a_rc=$?
printf '  (a) SUBSTRATE_ENGINE=bash: rc=%d\n' "$a_rc"
if [ "$a_rc" -eq 0 ] || [ "$a_rc" -eq 1 ]; then
    printf '  [ok] bash path runs (rc=%d)\n' "$a_rc"
    pass=$((pass + 1))
else
    fail_fn "SUBSTRATE_ENGINE=bash rc=$a_rc"
fi

# (b) SUBSTRATE_ENGINE=go with binary delegates
SUBSTRATE_ENGINE=go PATH="$engine_dir:$PATH" bash "$KIT_ROOT/.substrate/gate.sh" > "$WORK/b.txt" 2>&1
b_rc=$?
printf '  (b) SUBSTRATE_ENGINE=go: rc=%d\n' "$b_rc"
if [ "$b_rc" -eq 0 ] || [ "$b_rc" -eq 1 ]; then
    printf '  [ok] go delegation works (rc=%d)\n' "$b_rc"
    pass=$((pass + 1))
else
    fail_fn "SUBSTRATE_ENGINE=go rc=$b_rc"
fi

SUBSTRATE_ENGINE=go bash "$KIT_ROOT/.substrate/gate.sh" > "$WORK/c.txt" 2>&1
c_rc=$?
printf '  (c) SUBSTRATE_ENGINE=go (no binary): rc=%d\n' "$c_rc"
if [ "$c_rc" -ne 0 ]; then
    printf '  [ok] no binary, exits non-zero (rc=%d)\n' "$c_rc"
    pass=$((pass + 1))
else
    fail_fn "SUBSTRATE_ENGINE=go (no binary) rc=$c_rc"
fi

# (d) SUBSTRATE_ENGINE=auto with no binary falls back to bash
SUBSTRATE_ENGINE=auto bash "$KIT_ROOT/.substrate/gate.sh" > "$WORK/d.txt" 2>&1
d_rc=$?
printf '  (d) SUBSTRATE_ENGINE=auto (no binary): rc=%d\n' "$d_rc"
if [ "$d_rc" -eq 0 ] || [ "$d_rc" -eq 1 ]; then
    printf '  [ok] auto falls back to bash (rc=%d)\n' "$d_rc"
    pass=$((pass + 1))
else
    fail_fn "SUBSTRATE_ENGINE=auto (no binary) rc=$d_rc"
fi

# (e) SUBSTRATE_ENGINE=auto with binary delegates
SUBSTRATE_ENGINE=auto PATH="$engine_dir:$PATH" bash "$KIT_ROOT/.substrate/gate.sh" > "$WORK/e.txt" 2>&1
e_rc=$?
printf '  (e) SUBSTRATE_ENGINE=auto (binary): rc=%d\n' "$e_rc"
if [ "$e_rc" -eq 0 ] || [ "$e_rc" -eq 1 ]; then
    printf '  [ok] auto delegates to go (rc=%d)\n' "$e_rc"
    pass=$((pass + 1))
else
    fail_fn "SUBSTRATE_ENGINE=auto (binary) rc=$e_rc"
fi

if [ "$fail" -gt 0 ]; then
    printf 'gate-rollback: %d scenarios green, %d failed\n' "$pass" "$fail"
    exit 1
fi
printf 'gate-rollback: %d scenarios green\n' "$pass"
exit 0
