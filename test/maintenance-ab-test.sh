#!/usr/bin/env bash
# Dual-leg A/B diff for maintenance transactions (A.S1).
# Mirrors maintenance-test.sh coverage as bash-vs-go over independent re-seeded fixtures. 11 scenarios.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$TEST_DIR/lib"
KIT_ROOT="$(cd "$TEST_DIR/.." && pwd)"
export SUBSTRATE_VENDOR_FROM_WORKTREE=1
export LC_ALL=C

source "$LIB_DIR/engine-fixture.sh"
source "$LIB_DIR/maintenance-fixture.sh"
engine_fixture_home
_engine_fixture_sdk_root "$T"
export XDG_CONFIG_HOME="$T/xdg-config"
mkdir -p "$XDG_CONFIG_HOME"
TMPDIR="${TMPDIR:-/tmp}"
WORK=$(mktemp -d "$TMPDIR/maintenance-ab.XXXXXX")
trap 'rm -rf "$WORK" "$T"' EXIT

pass=0
fail=0

fail_fn() {
    printf '  [XX] %s\n' "$1" >&2
    fail=$((fail + 1))
}

# Runners: maintenance bootstrap via bin/substrate.
run_maint_bash() {
    local out="$1" err="$2"; shift 2
    SUBSTRATE_ENGINE=bash SUBSTRATE_KIT_ROOT="$KIT_ROOT" \
        bash "$KIT_ROOT/bin/substrate" bootstrap --from-worktree "$@" > "$out" 2> "$err"
}

run_maint_go() {
    local out="$1" err="$2"; shift 2
    SUBSTRATE_ENGINE=go SUBSTRATE_ENGINE_BIN="$BIN" SUBSTRATE_KIT_ROOT="$KIT_ROOT" \
        bash "$KIT_ROOT/bin/substrate" bootstrap --from-worktree "$@" > "$out" 2> "$err"
}

BIN=$(mf_engine_build fail_fn "maintenance-ab") || exit 2

printf 'maintenance-ab: comparing bash vs go maintenance transactions\n'

# ── Scenario 1: clean git bootstrap ──────────────────────────
printf '\n[1/11] clean git bootstrap\n'
_noop() { :; }
mf_run_diff "git-clean" mf_setup_git _noop run_maint \
    --repo-only --accept-baseline

# ── Scenario 2: clean jj bootstrap ───────────────────────────
printf '\n[2/11] clean jj bootstrap\n'
mf_run_diff "jj-clean" mf_setup_jj _noop run_maint \
    --repo-only --accept-baseline

# ── Scenario 3: git dirty-work preservation + post-condition ─
printf '\n[3/11] git dirty-work preservation\n'
git_dirty_setup() {
    local dir="$1"
    cd "$dir" || return 1
    printf 'dirty-user-work\n' >> user.sh
    # Record pre-run hash for post-condition (both legs)
    sha256sum user.sh > "$WORK/$1-before.sha"
}
mf_run_diff "git-dirty" mf_setup_git git_dirty_setup run_maint \
    --checkpoint --repo-only
# Post-condition: user file unchanged on both legs
for leg in bash go; do
    d="$WORK/git-dirty-$leg"
    receipt="$d/.git/substrate/maintenance-receipt.json"
    if [ -f "$receipt" ]; then
        # sha256sum of user.sh should match pre-run
        pre=$(head -c64 "$WORK/$d-before.sha" 2>/dev/null)
        post=$(cd "$d" && sha256sum user.sh | head -c64)
        if [ -n "$pre" ] && [ "$pre" = "$post" ]; then
            printf '  [ok] git-dirty %s: user file preserved (sha match)\n' "$leg"
            pass=$((pass + 1))
        else
            fail_fn "git-dirty $leg: user file changed"
        fi
    else
        printf '  [--] git-dirty %s: no receipt (pre-flight failure)\n' "$leg"
    fi
done

# ── Scenario 4: push-gate receipt reuse (per leg) ────────────
printf '\n[4/11] push-gate receipt reuse\n'
push_gate_setup() {
    local dir="$1"
    cd "$dir" || return 1
    mkdir -p checks.d
    printf '#!/usr/bin/env bash\nexit 0\n' > checks.d/84-push.sh
    chmod +x checks.d/84-push.sh
    git add checks.d/84-push.sh
    git commit -q --no-verify -m 'chore: add push check'
    printf 'dirty-push-work\n' >> user.sh
}
# Use seeded diff for maintenance, then run push-gate per leg
d="$WORK/push-gate"
mf_setup_git "$d" || { fail_fn "push-gate: seed failed"; exit 1; }
push_gate_setup "$d" || { fail_fn "push-gate: setup failed"; exit 1; }
# bash leg: run maintenance then push-gate
"$KIT_ROOT/bin/substrate" bootstrap --checkpoint --repo-only \
    > "$WORK/bash-push-maint.out" 2> "$WORK/bash-push-maint.err"
(cd "$d" && .substrate/push-gate.sh) > "$WORK/bash-push.out" 2> "$WORK/bash-push.err"
bash_pg_rc=$?
# go leg: fresh seed + setup + maintenance + push-gate
d2="$WORK/push-gate-go"
mf_setup_git "$d2" || { fail_fn "push-gate: go seed failed"; exit 1; }
push_gate_setup "$d2" || { fail_fn "push-gate: go setup failed"; exit 1; }
SUBSTRATE_ENGINE=go SUBSTRATE_ENGINE_BIN="$BIN" SUBSTRATE_KIT_ROOT="$KIT_ROOT" \
    "$KIT_ROOT/bin/substrate" bootstrap --checkpoint --repo-only \
    > "$WORK/go-push-maint.out" 2> "$WORK/go-push-maint.err"
(cd "$d2" && SUBSTRATE_ENGINE=go SUBSTRATE_ENGINE_BIN="$BIN" .substrate/push-gate.sh) \
    > "$WORK/go-push.out" 2> "$WORK/go-push.err"
go_pg_rc=$?
if [ "$bash_pg_rc" -eq "$go_pg_rc" ] && [ "$bash_pg_rc" -eq 0 ]; then
    printf '  [ok] push-gate: both legs rc=0\n'
    pass=$((pass + 1))
else
    fail_fn "push-gate: exit code mismatch: bash=$bash_pg_rc go=$go_pg_rc"
fi

# ── Scenario 5: dirty-baseline overlap refusal ───────────────
printf '\n[5/11] dirty-baseline overlap refusal\n'
dirty_baseline_setup() {
    local dir="$1"
    cd "$dir" || return 1
    printf ' ' >> substrate-baseline.json
}
mf_run_diff "dirty-overlap" mf_setup_git dirty_baseline_setup run_maint \
    --checkpoint --repo-only

# ── Scenario 6: concurrent-work drift refusal ────────────────
printf '\n[6/11] concurrent-work drift refusal\n'
drift_setup() {
    local dir="$1"
    cd "$dir" || return 1
    mkdir -p checks.d
    printf '#!/usr/bin/env bash\nexit 0\n' > checks.d/86-concurrent.sh
    chmod +x checks.d/86-concurrent.sh
    git add checks.d/86-concurrent.sh
    git commit -q --no-verify -m 'chore: add concurrent check'
}
cat > "$WORK/drift.sh" <<'EOF'
#!/usr/bin/env bash
printf 'concurrent-drift\n' >> "$1/user.sh"
EOF
chmod +x "$WORK/drift.sh"
export SUBSTRATE_MAINTENANCE_TESTING=1
export SUBSTRATE_MAINTENANCE_TEST_HOOK="$WORK/drift.sh"
mf_run_diff "concurrent-drift" mf_setup_git drift_setup run_maint \
    --checkpoint --repo-only
unset SUBSTRATE_MAINTENANCE_TEST_HOOK SUBSTRATE_MAINTENANCE_TESTING

# ── Scenario 7: incomplete→recovery resume ──────────────────
printf '\n[7/11] incomplete→recovery resume\n'
recovery_setup() {
    local dir="$1"
    cd "$dir" || return 1
    mkdir -p checks.d
    printf '#!/usr/bin/env bash\nexit 0\n' > checks.d/87-recovery.sh
    chmod +x checks.d/87-recovery.sh
    git add checks.d/87-recovery.sh
    git commit -q --no-verify -m 'chore: add recovery check'
}
# Run incomplete + recovery per leg, compare combined output
for leg in bash go; do
    d="$WORK/recovery-$leg"
    mf_setup_git "$d" || { fail_fn "recovery $leg: seed failed"; exit 1; }
    cd "$d" || exit 1
    recovery_setup "$d" || { fail_fn "recovery $leg: setup failed"; exit 1; }
    runner="run_maint_$leg"
    export SUBSTRATE_MAINTENANCE_TESTING=1
    export SUBSTRATE_MAINTENANCE_FAIL_AFTER=1
    "$runner" "$WORK/$leg-recovery-incomplete.out" "$WORK/$leg-recovery-incomplete.err" \
        --checkpoint --repo-only || true
    unset SUBSTRATE_MAINTENANCE_FAIL_AFTER SUBSTRATE_MAINTENANCE_TESTING
    "$runner" "$WORK/$leg-recovery-commit.out" "$WORK/$leg-recovery-commit.err" \
        --checkpoint --repo-only
    cat "$WORK/$leg-recovery-incomplete.out" "$WORK/$leg-recovery-commit.out" \
        > "$WORK/$leg-recovery-combined.out"
done
bash_masked="$WORK/bash-recovery-masked.out" go_masked="$WORK/go-recovery-masked.out"
mf_mask < "$WORK/bash-recovery-combined.out" > "$bash_masked"
mf_mask < "$WORK/go-recovery-combined.out" > "$go_masked"
if diff -u "$bash_masked" "$go_masked" > "$WORK/diff-recovery.out" 2>&1; then
    printf '  [ok] recovery: byte-identical after masking\n'
    pass=$((pass + 1))
else
    printf '  [XX] recovery: masked output differs — see %s\n' "$WORK/diff-recovery.out"
    fail=$((fail + 1))
fi

# ── Scenario 8: exact-commit-failure resume ──────────────────
printf '\n[8/11] exact-commit-failure resume\n'
commit_fail_setup() {
    local dir="$1"
    cd "$dir" || return 1
    mkdir -p checks.d
    printf '#!/usr/bin/env bash\nexit 0\n' > checks.d/88-commit-recovery.sh
    chmod +x checks.d/88-commit-recovery.sh
    git add checks.d/88-commit-recovery.sh
    git commit -q --no-verify -m 'chore: add commit recovery check'
}
for leg in bash go; do
    d="$WORK/commit-fail-$leg"
    mf_setup_git "$d" || { fail_fn "commit-fail $leg: seed failed"; exit 1; }
    cd "$d" || exit 1
    commit_fail_setup "$d" || { fail_fn "commit-fail $leg: setup failed"; exit 1; }
    runner="run_maint_$leg"
    export SUBSTRATE_MAINTENANCE_TESTING=1
    export SUBSTRATE_MAINTENANCE_FAIL_COMMIT=1
    "$runner" "$WORK/$leg-commit-fail.out" "$WORK/$leg-commit-fail.err" \
        --checkpoint --repo-only || true
    unset SUBSTRATE_MAINTENANCE_FAIL_COMMIT SUBSTRATE_MAINTENANCE_TESTING
    "$runner" "$WORK/$leg-commit-recovery.out" "$WORK/$leg-commit-recovery.err" \
        --checkpoint --repo-only
    cat "$WORK/$leg-commit-fail.out" "$WORK/$leg-commit-recovery.out" \
        > "$WORK/$leg-commit-fail-combined.out"
done
mf_mask < "$WORK/bash-commit-fail-combined.out" > "$WORK/bash-cf-masked.out"
mf_mask < "$WORK/go-commit-fail-combined.out" > "$WORK/go-cf-masked.out"
if diff -u "$WORK/bash-cf-masked.out" "$WORK/go-cf-masked.out" > "$WORK/diff-commit-fail.out" 2>&1; then
    printf '  [ok] commit-fail: byte-identical after masking\n'
    pass=$((pass + 1))
else
    printf '  [XX] commit-fail: masked output differs — see %s\n' "$WORK/diff-commit-fail.out"
    fail=$((fail + 1))
fi

# ── Scenario 9: applied-authorization non-checkpoint ─────────
printf '\n[9/11] applied-authorization non-checkpoint\n'
applied_setup() {
    local dir="$1"
    cd "$dir" || return 1
    mkdir -p checks.d
    printf '#!/usr/bin/env bash\nexit 0\n' > checks.d/89-applied.sh
    chmod +x checks.d/89-applied.sh
    git add checks.d/89-applied.sh
    git commit -q --no-verify -m 'chore: add applied check'
}
mf_run_diff "applied-non-checkpoint" mf_setup_git applied_setup run_maint \
    --repo-only

# ── Scenario 10: idempotent rerun ────────────────────────────
printf '\n[10/11] idempotent rerun\n'
# Re-seed per leg, run bootstrap twice
for leg in bash go; do
    d="$WORK/idempotent-$leg"
    mf_setup_git "$d" || { fail_fn "idempotent $leg: seed failed"; exit 1; }
    cd "$d" || exit 1
    runner="run_maint_$leg"
    "$runner" "$WORK/$leg-idem1.out" "$WORK/$leg-idem1.err" --repo-only --accept-baseline
    "$runner" "$WORK/$leg-idem2.out" "$WORK/$leg-idem2.err" --repo-only
    cat "$WORK/$leg-idem1.out" "$WORK/$leg-idem2.out" > "$WORK/$leg-idempotent-combined.out"
done
mf_mask < "$WORK/bash-idempotent-combined.out" > "$WORK/bash-idem-masked.out"
mf_mask < "$WORK/go-idempotent-combined.out" > "$WORK/go-idem-masked.out"
if diff -u "$WORK/bash-idem-masked.out" "$WORK/go-idem-masked.out" > "$WORK/diff-idempotent.out" 2>&1; then
    printf '  [ok] idempotent: byte-identical after masking\n'
    pass=$((pass + 1))
else
    printf '  [XX] idempotent: masked output differs — see %s\n' "$WORK/diff-idempotent.out"
    fail=$((fail + 1))
fi

# ── Scenario 11: --json bootstrap ────────────────────────────
printf '\n[11/11] --json bootstrap\n'
mf_run_diff "json-bootstrap" mf_setup_git _noop run_maint \
    --repo-only --accept-baseline --json

if [ "$fail" -gt 0 ]; then
    printf '\nmaintenance-ab: %d scenarios green, %d failed\n' "$pass" "$fail"
    exit 1
fi
printf '\nmaintenance-ab: %d scenarios green\n' "$pass"
exit 0
