#!/usr/bin/env bash
# Maintenance dual-leg A/B fixture + masking primitives (A.S0).
# Sourced, never run directly. Sources engine-fixture.sh for engine_build.
set -uo pipefail

AB_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$AB_LIB_DIR/engine-fixture.sh"

export LC_ALL=C
export SUBSTRATE_VENDOR_FROM_WORKTREE=1
export SUBSTRATE_NO_USER_HARNESS=1
# Thin wrapper over engine_build.
mf_engine_build() {
    local fail_fn="$1" label="$2"
    shift 2
    engine_build "$fail_fn" "$label" "$@"
}

# Seed a git repo identical to transaction-ab-test.sh:89-114.
mf_setup_git() {
    local dir="$1"
    mkdir -p "$dir" || return 1
    cd "$dir" || return 1
    git init -q --initial-branch=main
    git config user.name substrate
    git config user.email substrate@localhost
    printf '#!/usr/bin/env bash\nprintf "hello\\n"\n' > owned.sh
    chmod +x owned.sh
    printf '#!/usr/bin/env bash\nprintf "user\\n"\n' > user.sh
    chmod +x user.sh
    "$KIT_ROOT/bin/substrate" init --from-worktree --profile shell --vcs git >/dev/null 2>&1 || return 1
    .substrate/gate.sh --update-baseline >/dev/null 2>&1 || return 1
    git add -A
    git commit -qm 'chore: initialize'
    [ -z "$(git status --porcelain=v1 --untracked-files=all)" ] || return 1
}

# Seed a jj repo identical to transaction-ab-test.sh:117-132.
mf_setup_jj() {
    local dir="$1"
    mkdir -p "$dir" || return 1
    cd "$dir" || return 1
    jj config set --user user.name substrate >/dev/null 2>&1
    jj config set --user user.email substrate@localhost >/dev/null 2>&1
    git init -q --initial-branch=main
    jj git init --colocate . >/dev/null 2>&1 || return 1
    printf '#!/usr/bin/env bash\nprintf "hello\\n"\n' > owned.sh
    chmod +x owned.sh
    printf '#!/usr/bin/env bash\nprintf "user\\n"\n' > user.sh
    chmod +x user.sh
    "$KIT_ROOT/bin/substrate" init --from-worktree --profile shell --vcs jj >/dev/null 2>&1 || return 1
    .substrate/gate.sh --update-baseline >/dev/null 2>&1 || return 1
    jj commit -m 'chore: initialize' >/dev/null 2>&1 || return 1
}

# ── Masking ──────────────────────────────────────────────────

# Normalize maintenance output: hashes, fingerprints, durations, ANSI, ratchet lines. Pipe through.
mf_mask() {
    sed -E \
        -e 's/\b[0-9a-f]{64}\b/<sha256>/g' \
        -e 's/\b[0-9a-f]{40}\b/<sha>/g' \
        -e 's/[0-9a-f]{7,}/<shortsha>/g' \
        -e 's/\x1b\[[0-9;]*m//g' \
        -e 's/\([0-9]+(\.[0-9]+)?(ms|s)\)/(<duration>)/g' \
        -e 's/^[a-zA-Z0-9_\/:.-]+: [-0-9.eE+]+ \(best .+$/[ratchet]/' \
        -e 's/^\[.\] gate: [0-9]+ check\(s\) failed \([^)]+\)/[gate failed]/' \
        -e 's/ \[[0-9]+\/[0-9]+\]//g' \
        -e 's/ \([0-9]+ checks\)$//'
}

# Mask per-commit receipt fields, leaving changedPaths/units/manifest intact.
mf_mask_json() {
    local receipt="$1"
    jq '
        if type == "object" then
            if has("commit") then .commit = "<sha>" else . end |
            if has("toRevision") then .toRevision = "<sha>" else . end |
            if has("fromRevision") then .fromRevision = "<sha>" else . end |
            if has("gateHash") then .gateHash = "<sha256>" else . end |
            if has("preservedDirtyFingerprint") then .preservedDirtyFingerprint = "<sha256>" else . end |
            if has("engineVersion") then .engineVersion = "<engineVersion>" else . end |
            walk(if type == "object" then
                if has("commit") then .commit = "<sha>" else . end |
                if has("toRevision") then .toRevision = "<sha>" else . end |
                if has("fromRevision") then .fromRevision = "<sha>" else . end |
                if has("gateHash") then .gateHash = "<sha256>" else . end |
                if has("preservedDirtyFingerprint") then .preservedDirtyFingerprint = "<sha256>" else . end |
                if has("engineVersion") then .engineVersion = "<engineVersion>" else . end
            else . end)
        else . end
    ' "$receipt"
}

# ── A/B diff drivers ─────────────────────────────────────────

# Simple diff: bash leg runs first, go leg second, in the same directory.
# Use only for idempotent or non-mutating scenarios.
mf_simple_diff() {
    local label="$1" runner="$2"
    shift 2

    local bash_out="$WORK/bash-$label.out" go_out="$WORK/go-$label.out"
    local bash_err="$WORK/bash-$label.err" go_err="$WORK/go-$label.err"

    "${runner}"_bash "$bash_out" "$bash_err" "$@"
    local bash_rc=$?

    "${runner}"_go "$go_out" "$go_err" "$@"
    local go_rc=$?

    _mf_compare "$label" "$bash_rc" "$go_rc" "$bash_out" "$go_out" "$bash_err" "$go_err"
}

# Seeded diff: creates two fresh repos from fixture_fn, runs setup_fn between seed and run, then compares. gate:allow-comment
mf_run_diff() {
    local label="$1" fixture_fn="$2" setup_fn="$3" runner="$4"
    shift 4

    local bash_out="$WORK/bash-$label.out" go_out="$WORK/go-$label.out"
    local bash_err="$WORK/bash-$label.err" go_err="$WORK/go-$label.err"

    # bash leg
    local bash_dir="$WORK/$label-bash"
    "$fixture_fn" "$bash_dir" || { fail_fn "$label: bash fixture seed failed"; return 1; }
    cd "$bash_dir" || return 1
    if declare -F "$setup_fn" >/dev/null 2>&1; then
        "$setup_fn" "$bash_dir" || { fail_fn "$label: bash setup failed"; return 1; }
    fi
    "${runner}"_bash "$bash_out" "$bash_err" "$@"
    local bash_rc=$?

    # go leg
    local go_dir="$WORK/$label-go"
    "$fixture_fn" "$go_dir" || { fail_fn "$label: go fixture seed failed"; return 1; }
    cd "$go_dir" || return 1
    if declare -F "$setup_fn" >/dev/null 2>&1; then
        "$setup_fn" "$go_dir" || { fail_fn "$label: go setup failed"; return 1; }
    fi
    "${runner}"_go "$go_out" "$go_err" "$@"
    local go_rc=$?

    _mf_compare "$label" "$bash_rc" "$go_rc" "$bash_out" "$go_out" "$bash_err" "$go_err"
}

# Internal: compare exit codes, masked stdout, masked stderr.
_mf_compare() {
    local label="$1" bash_rc="$2" go_rc="$3" bash_out="$4" go_out="$5" bash_err="$6" go_err="$7"

    if [ "$bash_rc" -ne "$go_rc" ]; then
        fail_fn "$label: exit code mismatch: bash=$bash_rc go=$go_rc"
    else
        printf '  [ok] %s: exit %d matches\n' "$label" "$bash_rc"
        pass=$((pass + 1))
    fi

    local bash_masked="$WORK/bash-$label-masked.out" go_masked="$WORK/go-$label-masked.out"
    mf_mask < "$bash_out" > "$bash_masked"
    mf_mask < "$go_out" > "$go_masked"
    if diff -u "$bash_masked" "$go_masked" > "$WORK/diff-$label.out" 2>&1; then
        printf '  [ok] %s stdout: byte-identical after masking\n' "$label"
        pass=$((pass + 1))
    else
        printf '  [XX] %s stdout: content differs — see %s\n' "$label" "$WORK/diff-$label.out"
        fail=$((fail + 1))
    fi

    local bash_masked_err="$WORK/bash-$label-masked.err" go_masked_err="$WORK/go-$label-masked.err"
    mf_mask < "$bash_err" > "$bash_masked_err"
    mf_mask < "$go_err" > "$go_masked_err"
    if diff -u "$bash_masked_err" "$go_masked_err" > "$WORK/diff-$label.err" 2>&1; then
        printf '  [ok] %s stderr: byte-identical after masking\n' "$label"
        pass=$((pass + 1))
    else
        printf '  [--] %s stderr: diverges (A32 structural limit)\n' "$label"
    fi
}

# Exit-code-only A/B for A17 verbs where stderr differs structurally (A32).
# Usage: mf_run_diff_rc_only <label> <runner_prefix> [args...]
mf_run_diff_rc_only() {
    local label="$1" runner="$2"
    shift 2

    local bash_out="$WORK/bash-$label.out" go_out="$WORK/go-$label.out"
    local bash_err="$WORK/bash-$label.err" go_err="$WORK/go-$label.err"

    "${runner}"_bash "$bash_out" "$bash_err" "$@"
    local bash_rc=$?

    "${runner}"_go "$go_out" "$go_err" "$@"
    local go_rc=$?

    if [ "$bash_rc" -ne "$go_rc" ]; then
        fail_fn "$label: exit code mismatch: bash=$bash_rc go=$go_rc"
    else
        printf '  [ok] %s: exit %d matches (A17 verb; stderr divergence per A32)\n' "$label" "$bash_rc"
        pass=$((pass + 1))
    fi
}
