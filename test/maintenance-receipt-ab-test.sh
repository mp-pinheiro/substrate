#!/usr/bin/env bash
# A17 verbs dual-leg exit-code comparison (A.S3).
# verify-transition, repository-receipt-matches, receipt-matches.
# Re-seeds per leg via mf_seeded_rc_diff to isolate bootstrap commits.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$TEST_DIR/lib"
KIT_ROOT="$(cd "$TEST_DIR/.." && pwd)"

source "$LIB_DIR/maintenance-fixture.sh"

TMPDIR="${TMPDIR:-/tmp}"
WORK=$(mktemp -d "$TMPDIR/maintenance-receipt-ab.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

fail_fn() {
    printf '  [XX] %s\n' "$1" >&2
    fail=$((fail + 1))
}

BIN=$(mf_engine_build fail_fn "maintenance-receipt-ab") || exit 2

# Runners for A17 verbs: both write nothing to stdout, compare exit codes only (A32).
run_verb_bash() {
    local out="$1" err="$2"; shift 2
    bash .substrate/maintenance-lib.sh "$@" > "$out" 2> "$err"
}

run_verb_go() {
    local out="$1" err="$2"; shift 2
    "$BIN" maintenance "$@" > "$out" 2> "$err"
}

# mf_seeded_rc_diff: seed, setup, bootstrap, then run A17 verb on both legs; compare exit codes only (A32). gate:allow-comment
mf_seeded_rc_diff() {
    local label="$1" fixture_fn="$2" setup_fn="$3" verb="$4"
    shift 4


    # bash leg
    local bash_dir="$WORK/$label-bash"
    "$fixture_fn" "$bash_dir" || { fail_fn "$label: bash seed failed"; return 1; }
    cd "$bash_dir" || return 1
    if declare -F "$setup_fn" >/dev/null 2>&1; then
        "$setup_fn" "$bash_dir" || { fail_fn "$label: bash setup failed"; return 1; }
    fi
    SUBSTRATE_ENGINE=bash SUBSTRATE_KIT_ROOT="$KIT_ROOT" \
        bash "$KIT_ROOT/bin/substrate" bootstrap --repo-only --accept-baseline \
        > "$WORK/$label-bash-bootstrap.out" 2> "$WORK/$label-bash-bootstrap.err"
    run_verb_bash "$WORK/$label-bash-verb.out" "$WORK/$label-bash-verb.err" "$verb" "$@"
    local bash_rc=$?

    # go leg
    local go_dir="$WORK/$label-go"
    "$fixture_fn" "$go_dir" || { fail_fn "$label: go seed failed"; return 1; }
    cd "$go_dir" || return 1
    if declare -F "$setup_fn" >/dev/null 2>&1; then
        "$setup_fn" "$go_dir" || { fail_fn "$label: go setup failed"; return 1; }
    fi
    SUBSTRATE_ENGINE=go SUBSTRATE_ENGINE_BIN="$BIN" SUBSTRATE_KIT_ROOT="$KIT_ROOT" \
        bash "$KIT_ROOT/bin/substrate" bootstrap --repo-only --accept-baseline \
        > "$WORK/$label-go-bootstrap.out" 2> "$WORK/$label-go-bootstrap.err"
    run_verb_go "$WORK/$label-go-verb.out" "$WORK/$label-go-verb.err" "$verb" "$@"
    local go_rc=$?

    if [ "$bash_rc" -ne "$go_rc" ]; then
        fail_fn "$label: exit code mismatch: bash=$bash_rc go=$go_rc"
    else
        printf '  [ok] %s: exit %d matches (A17 verb; stderr divergence per A32)\n' "$label" "$bash_rc"
        pass=$((pass + 1))
    fi
    mkdir -p "$WORK/$label-receipt"
    local bash_receipt="$bash_dir/.git/substrate/maintenance-receipt.json"
    local go_receipt="$go_dir/.git/substrate/maintenance-receipt.json"
    [ -f "$bash_receipt" ] && cp "$bash_receipt" "$WORK/$label-receipt/bash-receipt.json"
    [ -f "$go_receipt" ] && cp "$go_receipt" "$WORK/$label-receipt/go-receipt.json"
}

_noop() { :; }

printf 'maintenance-receipt-ab: A17 verbs dual-leg exit-code comparison\n'

# ── Scenario 1: verify-transition match ──────────────────────
printf '\n[1/10] verify-transition match\n'
mf_seeded_rc_diff "verify-match" mf_setup_git _noop \
    verify-transition __FROM__ __TO__ __FP__
# Fill in real values from receipt
receipt="$WORK/verify-match-receipt/bash-receipt.json"
from=$(jq -r '.repository.fromRevision' "$receipt")
to=$(jq -r '.repository.commit' "$receipt")
fp=$(jq -r '.preservedDirtyFingerprint' "$receipt")
# Re-run with real values (both legs re-seeded again)
mf_seeded_rc_diff "verify-match-real" mf_setup_git _noop \
    verify-transition "$from" "$to" "$fp"

# ── Scenario 2: verify-transition stale revision ─────────────
printf '\n[2/10] verify-transition stale revision\n'
mf_seeded_rc_diff "verify-stale" mf_setup_git _noop \
    verify-transition deadbeefdeadbeefdeadbeefdeadbeefdeadbeef "$to" "$fp"

# ── Scenario 3: verify-transition changed-path mismatch ──────
printf '\n[3/10] verify-transition path mismatch\n'
mf_seeded_rc_diff "verify-path-mismatch" mf_setup_git _noop \
    verify-transition "$from" "$to" badfingerprintbadfingerprintbadfingerprintbad

# ── Scenario 4: verify-transition missing receipt ────────────
printf '\n[4/10] verify-transition missing receipt\n'
d="$WORK/verify-missing"
mf_setup_git "$d" && cd "$d" || exit 1
run_verb_bash "$WORK/verify-missing-bash.out" "$WORK/verify-missing-bash.err" \
    verify-transition a b c
bash_rc=$?
d2="$WORK/verify-missing-go"
mf_setup_git "$d2" && cd "$d2" || exit 1
run_verb_go "$WORK/verify-missing-go.out" "$WORK/verify-missing-go.err" \
    verify-transition a b c
go_rc=$?
if [ "$bash_rc" -eq "$go_rc" ]; then
    printf '  [ok] verify-transition missing: exit %d matches (A17 verb; stderr divergence per A32)\n' "$bash_rc"
    pass=$((pass + 1))
else
    fail_fn "verify-transition missing: exit code mismatch: bash=$bash_rc go=$go_rc"
fi

# ── Scenario 5: verify-transition bad argc ───────────────────
printf '\n[5/10] verify-transition bad argc\n'
d="$WORK/verify-bad-argc"
mf_setup_git "$d" && cd "$d" || exit 1
run_verb_bash "$WORK/verify-bad-argc-bash.out" "$WORK/verify-bad-argc-bash.err" \
    verify-transition a b
bash_rc=$?
d2="$WORK/verify-bad-argc-go"
mf_setup_git "$d2" && cd "$d2" || exit 1
run_verb_go "$WORK/verify-bad-argc-go.out" "$WORK/verify-bad-argc-go.err" \
    verify-transition a b
go_rc=$?
if [ "$bash_rc" -eq "$go_rc" ]; then
    printf '  [ok] verify-transition bad argc: exit %d matches (A17 verb; stderr divergence per A32)\n' "$bash_rc"
    pass=$((pass + 1))
else
    fail_fn "verify-transition bad argc: exit code mismatch: bash=$bash_rc go=$go_rc"
fi

# ── Scenario 6: repository-receipt-matches match ─────────────
printf '\n[6/10] repository-receipt-matches match\n'
mf_seeded_rc_diff "repo-matches" mf_setup_git _noop \
    repository-receipt-matches __PLACEHOLDER__

# ── Scenario 7: repository-receipt-matches stale ─────────────
printf '\n[7/10] repository-receipt-matches stale\n'
repo_stale_setup() {
    local dir="$1"
    cd "$dir" || return 1
    printf '#!/usr/bin/env bash\nexit 0\n' > checks.d/86-stale.sh
    chmod +x checks.d/86-stale.sh
}
mf_seeded_rc_diff "repo-stale" mf_setup_git repo_stale_setup \
    repository-receipt-matches __PLACEHOLDER__

# ── Scenario 8: receipt-matches match ────────────────────────
printf '\n[8/10] receipt-matches match (clean repo)\n'
mf_seeded_rc_diff "receipt-matches" mf_setup_git _noop \
    receipt-matches __PLACEHOLDER__

# ── Scenario 9: receipt-matches repoRuntime failed ───────────
printf '\n[9/10] receipt-matches repoRuntime not-passed\n'
runtime_fail_setup() {
    local dir="$1"
    cd "$dir" || return 1
    # Bootstrap first to get a receipt, then corrupt it
    SUBSTRATE_ENGINE=bash SUBSTRATE_KIT_ROOT="$KIT_ROOT" \
        bash "$KIT_ROOT/bin/substrate" bootstrap --repo-only --accept-baseline \
        > /dev/null 2>&1
    local receipt="$dir/.git/substrate/maintenance-receipt.json"
    jq '.repoRuntime.status = "failed"' "$receipt" > "$receipt.tmp"
    mv "$receipt.tmp" "$receipt"
}
# Special handling: setup_fn does the bootstrap+corruption, then we only run the verb
for leg in bash go; do
    d="$WORK/receipt-runtime-$leg"
    mf_setup_git "$d" || { fail_fn "receipt-runtime $leg: seed failed"; exit 1; }
    cd "$d" || exit 1
    runtime_fail_setup "$d"
done
# bash verb
d="$WORK/receipt-runtime-bash"
cd "$d" || exit 1
run_verb_bash "$WORK/runtime-bash.out" "$WORK/runtime-bash.err" receipt-matches __PLACEHOLDER__
bash_rc=$?
# go verb
d="$WORK/receipt-runtime-go"
cd "$d" || exit 1
run_verb_go "$WORK/runtime-go.out" "$WORK/runtime-go.err" receipt-matches __PLACEHOLDER__
go_rc=$?
if [ "$bash_rc" -eq "$go_rc" ]; then
    printf '  [ok] receipt-matches runtime-fail: exit %d matches (A17 verb; stderr divergence per A32)\n' "$bash_rc"
    pass=$((pass + 1))
else
    fail_fn "receipt-matches runtime-fail: exit code mismatch: bash=$bash_rc go=$go_rc"
fi

# ── Scenario 10: receipt-matches bad argc (bash-only) ────────
printf '\n[10/10] receipt-matches bad argc (bash-only)\n'
d="$WORK/receipt-bad-argc"
mf_setup_git "$d" && cd "$d" || exit 1
# Bash leg: maintenance-lib.sh checks [ $# -eq 1 ]; passing extra arg → rc 2
bash .substrate/maintenance-lib.sh receipt-matches extra-arg \
    > "$WORK/receipt-bad-argc-bash.out" 2> "$WORK/receipt-bad-argc-bash.err"
bash_rc=$?
if [ "$bash_rc" -eq 2 ]; then
    printf '  [ok] receipt-matches bad argc: bash rc=2 (go unreachable by design — structural argv diff)\n'
    pass=$((pass + 1))
else
    fail_fn "receipt-matches bad argc: bash rc=$bash_rc expected 2"
fi

if [ "$fail" -gt 0 ]; then
    printf '\nmaintenance-receipt-ab: %d scenarios green, %d failed\n' "$pass" "$fail"
    exit 1
fi
printf '\nmaintenance-receipt-ab: %d scenarios green\n' "$pass"
exit 0
