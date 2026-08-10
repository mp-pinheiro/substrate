#!/usr/bin/env bash
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$TEST_DIR/lib"
KIT_ROOT="$(cd "$TEST_DIR/.." && pwd)"

source "$LIB_DIR/engine-fixture.sh"
source "$LIB_DIR/maintenance-fixture.sh"
engine_fixture_home
_engine_fixture_sdk_root "$T"
export XDG_CONFIG_HOME="$T/xdg-config"
mkdir -p "$XDG_CONFIG_HOME"
TMPDIR="${TMPDIR:-/tmp}"
WORK=$(mktemp -d "$TMPDIR/maintenance-receipt-ab.XXXXXX")
trap 'rm -rf "$WORK" "$T"' EXIT

pass=0
fail=0

fail_fn() {
    printf '  [XX] %s\n' "$1" >&2
    fail=$((fail + 1))
}

BIN=$(mf_engine_build fail_fn "maintenance-receipt-ab") || exit 2

run_verb() {
    local out="$1" err="$2"; shift 2
    "$BIN" maintenance "$@" > "$out" 2> "$err"
}

expect_rc() {
    local label="$1" rc="$2" want="$3"
    if { [ "$want" -eq 0 ] && [ "$rc" -eq 0 ]; } || { [ "$want" -ne 0 ] && [ "$rc" -ne 0 ]; }; then
        printf '  [ok] %s: exit %d\n' "$label" "$rc"
        pass=$((pass + 1))
    else
        fail_fn "$label: expected $want, got $rc"
    fi
}

mf_run_verb() {
    local label="$1" fixture_fn="$2" setup_fn="$3" expect="$4" verb="$5"
    shift 5

    local dir="$WORK/$label"
    "$fixture_fn" "$dir" || { fail_fn "$label: seed failed"; return 1; }
    cd "$dir" || return 1
    if declare -F "$setup_fn" >/dev/null 2>&1; then
        "$setup_fn" "$dir" || { fail_fn "$label: setup failed"; return 1; }
    fi
    SUBSTRATE_ENGINE_BIN="$BIN" SUBSTRATE_KIT_ROOT="$KIT_ROOT" \
        bash "$KIT_ROOT/bin/substrate" bootstrap --checkpoint --repo-only --accept-baseline \
        > "$WORK/$label-bootstrap.out" 2> "$WORK/$label-bootstrap.err"
    run_verb "$WORK/$label-verb.out" "$WORK/$label-verb.err" "$verb" "$@"
    local rc=$?
    expect_rc "$label" "$rc" "$expect"

    mkdir -p "$WORK/$label-receipt"
    local receipt="$dir/.git/substrate/maintenance-receipt.json"
    [ -f "$receipt" ] && cp "$receipt" "$WORK/$label-receipt/receipt.json"
}

_noop() { :; }

printf 'maintenance-receipt-ab: go-only A17 verb verification\n'

printf '\n[1/9] verify-transition match\n'
mf_run_verb "verify-match" mf_setup_git _noop 1 \
    verify-transition __FROM__ __TO__ __FP__
receipt="$WORK/verify-match-receipt/receipt.json"
from=$(jq -r '.repository.fromRevision' "$receipt")
to=$(jq -r '.repository.toRevision' "$receipt")
fp=$(jq -r '.repository.preservedDirtyFingerprint' "$receipt")
cd "$WORK/verify-match" || exit 1
run_verb "$WORK/verify-match-real.out" "$WORK/verify-match-real.err" \
    verify-transition "$from" "$to" "$fp"
expect_rc "verify-match-real" "$?" 0

printf '\n[2/9] verify-transition stale revision\n'
mf_run_verb "verify-stale" mf_setup_git _noop 1 \
    verify-transition deadbeefdeadbeefdeadbeefdeadbeefdeadbeef "$to" "$fp"

printf '\n[3/9] verify-transition path mismatch\n'
mf_run_verb "verify-path-mismatch" mf_setup_git _noop 1 \
    verify-transition "$from" "$to" badfingerprintbadfingerprintbadfingerprintbad

printf '\n[4/9] verify-transition missing receipt\n'
d="$WORK/verify-missing"
mf_setup_git "$d" && cd "$d" || exit 1
run_verb "$WORK/verify-missing.out" "$WORK/verify-missing.err" \
    verify-transition a b c
expect_rc "verify-missing" "$?" 1

printf '\n[5/9] verify-transition bad argc\n'
d="$WORK/verify-bad-argc"
mf_setup_git "$d" && cd "$d" || exit 1
run_verb "$WORK/verify-bad-argc.out" "$WORK/verify-bad-argc.err" \
    verify-transition a b
rc=$?
if [ "$rc" -eq 2 ]; then
    printf '  [ok] verify-bad-argc: rc=2 (usage error)\n'
    pass=$((pass + 1))
else
    fail_fn "verify-bad-argc: expected rc=2, got $rc"
fi

printf '\n[6/9] repository-receipt-matches match\n'
mf_run_verb "repo-matches" mf_setup_git _noop 0 \
    repository-receipt-matches __PLACEHOLDER__

printf '\n[7/9] repository-receipt-matches stale\n'
d="$WORK/repo-stale"
mf_setup_git "$d" || { fail_fn "repo-stale: seed failed"; exit 1; }
cd "$d" || exit 1
SUBSTRATE_ENGINE_BIN="$BIN" SUBSTRATE_KIT_ROOT="$KIT_ROOT" \
    bash "$KIT_ROOT/bin/substrate" bootstrap --checkpoint --repo-only --accept-baseline \
    > "$WORK/repo-stale-bootstrap.out" 2> "$WORK/repo-stale-bootstrap.err"
printf '#!/usr/bin/env bash\nexit 0\n' > checks.d/86-stale.sh
chmod +x checks.d/86-stale.sh
run_verb "$WORK/repo-stale.out" "$WORK/repo-stale.err" \
    repository-receipt-matches __PLACEHOLDER__
expect_rc "repo-stale" "$?" 1

printf '\n[8/9] receipt-matches match\n'
mf_run_verb "receipt-matches" mf_setup_git _noop 0 \
    receipt-matches __PLACEHOLDER__

printf '\n[9/9] receipt-matches repoRuntime not-passed\n'
d="$WORK/receipt-runtime"
mf_setup_git "$d" || { fail_fn "receipt-runtime: seed failed"; exit 1; }
cd "$d" || exit 1
SUBSTRATE_ENGINE_BIN="$BIN" SUBSTRATE_KIT_ROOT="$KIT_ROOT" \
    bash "$KIT_ROOT/bin/substrate" bootstrap --checkpoint --repo-only --accept-baseline \
    > /dev/null 2>&1
receipt="$d/.git/substrate/maintenance-receipt.json"
jq '.repoRuntime.status = "failed"' "$receipt" > "$receipt.tmp"
mv "$receipt.tmp" "$receipt"
run_verb "$WORK/runtime.out" "$WORK/runtime.err" \
    receipt-matches __PLACEHOLDER__
expect_rc "receipt-runtime" "$?" 1

if [ "$fail" -gt 0 ]; then
    printf '\nmaintenance-receipt-ab: %d scenarios green, %d failed\n' "$pass" "$fail"
    exit 1
fi
printf '\nmaintenance-receipt-ab: %d scenarios green\n' "$pass"
exit 0
