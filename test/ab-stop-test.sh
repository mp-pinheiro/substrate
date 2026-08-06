#!/usr/bin/env bash
# Stop-branch decision matrix for core/hooks/agent-lifecycle.sh (stop, 206-265):
# every exit of that branch gets a scratch colocated jj repo, a session ledger
# built through the real start/observe path, and a byte-compared capture of
# stdout, stderr, exit status and the whole ledger directory.
# WHY: .substrate/checkpoint.sh is a committed test double — the stop branch's
# contract with it is exit status, last stdout line and argv (all asserted
# below); the real transaction is checkpoint-test.sh's subject.
# Per-scenario jq ceilings are the measured post-0.1a counts (whole hook: payload
# parse + snapshot + the batched derivation + protocol writers), so any re-added
# fork reds. capture mode skips them so expectations record the current engine.
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/ab-diff.sh
source "$KIT_ROOT/test/lib/ab-diff.sh"

export LC_ALL=C
export SUBSTRATE_NO_USER_HARNESS=1

JQ_CEILING="${AB_STOP_JQ_CEILING:-8}"
JJ_CEILING="${AB_STOP_JJ_CEILING:-2}"
DRIFT_REVISION=0123456789abcdef0123456789abcdef01234567
STUB_COMMIT='{"commit":"fedcba9876543210fedcba9876543210fedcba98","status":"passed"}'
STUB_FAILURE='gate red: 60-shellcheck.sh'
TRACKING_TEXT='jj diff failed: probe'
CHECKPOINT_MESSAGE='chore(agent): checkpoint owned work at session stop'
SCENARIO_JJ=jj

T=$(mktemp -d) || exit 9
T=$(cd "$T" && pwd -P) || exit 9
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"
mkdir -p "$HOME" || exit 9

command -v jj >/dev/null 2>&1 || { printf 'ab-stop-test: jj is required\n' >&2; exit 9; }
export JJ_USER=substrate JJ_EMAIL=substrate@localhost

seed_repo() {
    local repo="$1"
    mkdir -p "$repo/.substrate/hooks" || return 1
    cp "$KIT_ROOT/core/hooks/agent-lifecycle.sh" "$repo/.substrate/hooks/" || return 1
    cp "$KIT_ROOT/core/engine-shim.sh" "$repo/.substrate/" || return 1
    cp "$KIT_ROOT/core/maintenance-lib.sh" "$KIT_ROOT/core/maintenance-receipt.sh" \
        "$repo/.substrate/" || return 1
    cat > "$repo/.substrate/checkpoint.sh" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
[ -z "${AB_STUB_ARGV:-}" ] || printf '%s\0' "$@" >> "$AB_STUB_ARGV"
printf '%s\n' "${AB_STUB_LINE:-}"
exit "${AB_STUB_EXIT:-0}"
SH
    chmod +x "$repo/.substrate/checkpoint.sh" || return 1
    printf 'printf "owned\\n"\n' > "$repo/owned.sh"
    printf 'printf "user\\n"\n' > "$repo/user.sh"
    (
        cd "$repo" || exit 9
        git init -q --initial-branch=main || exit 9
        jj git init --colocate . || exit 9
        jj commit -m 'chore: seed stop-path fixture' || exit 9
    ) >/dev/null 2>&1
}

lifecycle() {
    printf '{"session_id":"%s"}\n' "$2" \
        | ( cd "$1" && bash .substrate/hooks/agent-lifecycle.sh "$3" ) >/dev/null 2>&1
}

stop_payload() {
    printf '{"session_id":"%s","stop_hook_active":%s}\n' "$1" "$2"
}

# staging sits outside the watched ledger directory, so a failed patch cannot
# masquerade as hook residue in the capture
patch_state() {
    local ledger="$1/.git/substrate/agent-sessions/$2.json" staged="$1/.git/substrate/ab-patch.json"
    jq -c "$3" "$ledger" > "$staged" && mv -f "$staged" "$ledger"
}

head_revision() {
    ( cd "$1" && jj log -r @- --no-graph -T commit_id )
}

setup_no_ledger() {
    :
}

setup_clean_ledger() {
    lifecycle "$1" "$2" start
}

setup_completed_commit() {
    local revision
    setup_clean_ledger "$@" || return 1
    revision=$(head_revision "$1") || return 1
    patch_state "$1" "$2" ".initial.revision = \"$DRIFT_REVISION\" | .completedCommit = \"$revision\""
}

setup_tracking_clean() {
    setup_clean_ledger "$@" || return 1
    patch_state "$1" "$2" ".trackingError = \"$TRACKING_TEXT\""
}

setup_tracking_dirty() {
    setup_tracking_clean "$@" || return 1
    printf 'printf "user edit\\n"\n' >> "$1/user.sh"
}

setup_revision_drift() {
    setup_clean_ledger "$@" || return 1
    patch_state "$1" "$2" ".initial.revision = \"$DRIFT_REVISION\""
}

setup_unowned_blocked() {
    setup_revision_drift "$@" || return 1
    printf 'printf "user edit\\n"\n' >> "$1/user.sh"
    patch_state "$1" "$2" '.stopBlocked = true'
}

setup_owned_observed() {
    setup_clean_ledger "$@" || return 1
    printf 'printf "edited\\n"\n' >> "$1/owned.sh"
    lifecycle "$1" "$2" observe
}

setup_owned_unobserved() {
    setup_owned_observed "$@" || return 1
    printf 'printf "unobserved\\n"\n' >> "$1/owned.sh"
}

setup_owned_green() {
    setup_owned_observed "$@" || return 1
    ab_env AB_STUB_EXIT=0 "AB_STUB_LINE=$STUB_COMMIT" "AB_STUB_ARGV=$AB_SCENARIO_DIR/checkpoint-argv"
}

setup_owned_failed() {
    setup_owned_observed "$@" || return 1
    ab_env AB_STUB_EXIT=1 "AB_STUB_LINE=$STUB_FAILURE" "AB_STUB_ARGV=$AB_SCENARIO_DIR/checkpoint-argv"
}

setup_inspection_error() {
    setup_clean_ledger "$@" || return 1
    mkdir -p "$AB_SCENARIO_DIR/fail-bin" || return 1
    cat > "$AB_SCENARIO_DIR/fail-bin/jj" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = log ] || exit 0
printf 'jj log: probe failure\n' >&2
exit 1
SH
    chmod +x "$AB_SCENARIO_DIR/fail-bin/jj" || return 1
    SCENARIO_JJ="jj=$AB_SCENARIO_DIR/fail-bin/jj"
}

assert_checkpoint_argv() {
    local want="$AB_SCENARIO_DIR/checkpoint-argv.want"
    printf '%s\0' --session "$2" --message "$CHECKPOINT_MESSAGE" --json > "$want"
    cmp -s "$AB_SCENARIO_DIR/checkpoint-argv" "$want" \
        || ab_fail 'auto-checkpoint argv drifted from the frozen grammar'
}

scenario() {
    local name="$1" setup="$2" active="$3" assert="${4:-}" ceiling="${5:-$JQ_CEILING}"
    local repo session payload
    ab_begin "$name" || return 1
    session="ab-$name"
    repo="$AB_SCENARIO_DIR/repo"
    SCENARIO_JJ=jj
    if ! seed_repo "$repo" || ! "$setup" "$repo" "$session"; then
        ab_fail "setup $setup failed"
        ab_end
        return 1
    fi
    ab_mask "$repo" '<REPO>'
    ab_mask "$T" '<TMP>'
    ab_mask "$session" '<SESSION>'
    ab_watch .git/substrate/agent-sessions
    ab_shim jq "$SCENARIO_JJ" || return 1
    payload="$(stop_payload "$session" "$active")"$'\n'
    ab_run "$repo" "$payload" bash .substrate/hooks/agent-lifecycle.sh stop
    ab_ceiling jq "$ceiling"
    ab_ceiling jj "$JJ_CEILING"
    [ -z "$assert" ] || "$assert" "$repo" "$session"
    ab_end
}

ab_init ab-stop || exit 9

scenario no-session-state          setup_no_ledger        false ""                     1
scenario clean-tree-no-pending     setup_clean_ledger     false ""                     5
scenario completed-commit-bypass   setup_completed_commit false ""                     5
scenario tracking-error-suppressed setup_tracking_clean   false ""                     5
scenario owned-pending-checkpoint  setup_owned_green      false assert_checkpoint_argv  8
scenario owned-pending-auto-failed setup_owned_failed     false assert_checkpoint_argv  7
scenario owned-pending-reentry     setup_owned_observed   true  ""                     7
scenario owned-fingerprint-drift   setup_owned_unobserved false ""                     7
scenario revision-drift-clean      setup_revision_drift   false ""                     6
scenario unowned-drift-reblocked   setup_unowned_blocked  false ""                     7
scenario tracking-error-dirty      setup_tracking_dirty   false ""                     7
scenario inspection-error          setup_inspection_error false ""                     6

ab_report
