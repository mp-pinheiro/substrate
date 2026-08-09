#!/usr/bin/env bash
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$TEST_DIR/lib"
KIT_ROOT="$(cd "$TEST_DIR/.." && pwd)"

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

mask_durations() {
    sed -E \
        -e 's/\x1b\[[0-9;]*m//g' \
        -e 's/\([0-9]+(\.[0-9]+)?(ms|s)\)/(<duration>)/g' \
        -e 's/^\[.\] (FAIL )?ratchet: .+$/[ratchet]/' \
        -e 's/^[a-zA-Z0-9_/:.-]+: [-0-9.eE+]+ \(best .+$/[ratchet]/' \
        -e 's/^\[.\] gate: [0-9]+ check\(s\) failed \([^)]+\)/[gate failed]/'
}

report_diff() {
    local label="$1" bash_out="$2" go_out="$3"
    local bash_masked="$WORK/bash-masked.txt"
    local go_masked="$WORK/go-masked.txt"
    mask_durations < "$bash_out" | uniq > "$bash_masked"
    mask_durations < "$go_out" | uniq > "$go_masked"

    if diff -u "$bash_masked" "$go_masked" > "$WORK/diff.txt" 2>&1; then
        printf '  [ok] %s: byte-identical after duration masking\n' "$label"
        pass=$((pass + 1))
    else
        bash_lines=$(wc -l < "$bash_masked")
        go_lines=$(wc -l < "$go_masked")
        if [ "$bash_lines" -eq "$go_lines" ]; then
            printf '  [XX] %s: line count matches (%d) but content differs — see %s\n' "$label" "$bash_lines" "$WORK/diff.txt"
        else
            printf '  [XX] %s: line count mismatch: bash=%d go=%d — see %s\n' "$label" "$bash_lines" "$go_lines" "$WORK/diff.txt"
        fi
        fail=$((fail + 1))
        return 1
    fi
}

run_gate_bash() {
    local out="$1"
    SUBSTRATE_ENGINE=bash bash "$KIT_ROOT/.substrate/gate.sh" > "$out" 2>&1
}

run_gate_go() {
    local out="$1"
    local engine
    engine=$(engine_build fail_fn "gate-ab-test") || return 2
    "$engine" gate > "$out" 2>&1
}

printf 'gate-ab: comparing bash vs go gate output\n'

bash_out="$WORK/bash-gate.txt"
go_out="$WORK/go-gate.txt"

run_gate_bash "$bash_out"
bash_rc=$?
run_gate_go "$go_out"
go_rc=$?

printf '  bash exit: %d, go exit: %d\n' "$bash_rc" "$go_rc"

if [ "$bash_rc" -ne "$go_rc" ]; then
    printf '  [XX] exit code mismatch: bash=%d go=%d\n' "$bash_rc" "$go_rc"
    fail=$((fail + 1))
else
    printf '  [ok] exit codes match: %d\n' "$bash_rc"
    pass=$((pass + 1))
fi

report_diff "full gate" "$bash_out" "$go_out"

if [ "$fail" -gt 0 ]; then
    printf 'gate-ab: %d scenarios green, %d failed\n' "$pass" "$fail"
    exit 1
fi
printf 'gate-ab: %d scenarios green\n' "$pass"
exit 0
