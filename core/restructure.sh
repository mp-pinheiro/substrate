#!/usr/bin/env bash
# Gated jj restructure transaction: declarative split/describe/squash over
# agent-authored commits, atomic via op restore, receipted, never pushes.
set -uo pipefail

SUBSTRATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SUBSTRATE_DIR%/*}"
cd "$REPO_ROOT" || exit 2
# shellcheck source=./receipt-lib.sh
source "$SUBSTRATE_DIR/receipt-lib.sh" 2>/dev/null \
    || { printf 'restructure blocked: receipt runtime missing — run: substrate update --apply\n' >&2; exit 2; }

op=""
revision=""
into=""
message=""
message2=""
session=""
json=0
paths=()
allow_changes=()
usage() {
    printf 'usage: %s --op split|describe|squash --revision <rev> --message "type(scope): subject" [--message2 "type(scope): subject"] [--into <rev>] [--path <p> ...] (--session <id> | --allow-change <change-id> ...) [--json]\n' "$0" >&2
    exit 2
}
SAVED_ARGS=("$@")
while [ "$#" -gt 0 ]; do
    case "$1" in
        --op) [ "$#" -ge 2 ] || usage; op="$2"; shift 2 ;;
        --revision) [ "$#" -ge 2 ] || usage; revision="$2"; shift 2 ;;
        --into) [ "$#" -ge 2 ] || usage; into="$2"; shift 2 ;;
        --message) [ "$#" -ge 2 ] || usage; message="$2"; shift 2 ;;
        --message2) [ "$#" -ge 2 ] || usage; message2="$2"; shift 2 ;;
        --path) [ "$#" -ge 2 ] || usage; paths+=("$2"); shift 2 ;;
        --session) [ "$#" -ge 2 ] || usage; session="$2"; shift 2 ;;
        --allow-change) [ "$#" -ge 2 ] || usage; allow_changes+=("$2"); shift 2 ;;
        --json) json=1; shift ;;
        *) usage ;;
    esac
done
case "$op" in
    split|describe|squash) ;;
    *) usage ;;
esac
[ -n "$revision" ] || usage

source "$SUBSTRATE_DIR/engine-shim.sh"
ENGINE_MODE="${SUBSTRATE_ENGINE:-auto}"
if [ "$ENGINE_MODE" = "bash" ]; then
    :
elif substrate_engine_supports restructure; then
    if [ "$ENGINE_MODE" = "go" ] || [ "$ENGINE_MODE" = "auto" ]; then
        ${SUBSTRATE_ENGINE_BIN:-substrate-engine} restructure "${SAVED_ARGS[@]}"
        rc=$?
        [ "$rc" -eq 2 ] && { printf 'engine restructure returned unknown-verb after capability probe\n' >&2; exit 2; }
        exit "$rc"
    fi
elif [ "$ENGINE_MODE" = "go" ]; then
    printf 'SUBSTRATE_ENGINE=go but no substrate-engine binary found or its capabilities probe failed\n' >&2
    exit 2
fi

if [ ! -e .jj ] || ! command -v jj >/dev/null 2>&1 \
    || [ "$(jj root 2>/dev/null)" != "$REPO_ROOT" ]; then
    printf 'restructure blocked: requires a Jujutsu repository at the gate root\n' >&2
    exit 2
fi

conv='^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([^)]+\))?!?: [^[:space:]]'
[ -n "$message" ] && printf '%s\n' "$message" | grep -Eq "$conv" \
    || { printf 'restructure blocked: message must follow Conventional Commits — type(scope): subject\n' >&2; exit 2; }
if [ -n "$message2" ] && ! printf '%s\n' "$message2" | grep -Eq "$conv"; then
    printf 'restructure blocked: second message must follow Conventional Commits\n' >&2
    exit 2
fi
for candidate in "$revision" "$into"; do
    case "$candidate" in
        *[!A-Za-z0-9]*)
            printf 'restructure blocked: revisions must be plain change or commit ids: %s\n' "$candidate" >&2
            exit 2 ;;
    esac
done
normalized=()
for path in "${paths[@]}"; do
    path="${path#./}"
    substrate_safe_path "$path" \
        || { printf 'restructure blocked: unsafe path: %s\n' "$path" >&2; exit 2; }
    if [ -x .substrate/hooks/protect-paths.sh ] \
        && ! jq -n --arg path "$path" '{tool_input: {file_path: $path}}' \
            | .substrate/hooks/protect-paths.sh >/dev/null; then
        printf 'restructure blocked: governed path cannot be split out: %s\n' "$path" >&2
        exit 2
    fi
    normalized+=("$path")
done

METADATA=$(substrate_metadata_dir) \
    || { printf 'restructure blocked: no repository metadata found\n' >&2; exit 2; }
STATE=""
if [ -n "$session" ]; then
    case "$session" in
        ''|*[!A-Za-z0-9._-]*)
            printf 'restructure blocked: invalid session id\n' >&2
            exit 2 ;;
    esac
    STATE="$METADATA/substrate/agent-sessions/$session.json"
    [ -f "$STATE" ] || { printf 'restructure blocked: Claude ownership state is missing\n' >&2; exit 2; }
    [ "$(jq -r '.repoRoot' "$STATE")" = "$REPO_ROOT" ] \
        || { printf 'restructure blocked: ownership state belongs to another repository\n' >&2; exit 2; }
    mapfile -t allow_changes < <(jq -r '(.sessionChanges // [])[]' "$STATE")
fi
[ "${#allow_changes[@]}" -gt 0 ] \
    || { printf 'restructure blocked: no session-authored commits to restructure; checkpoint first\n' >&2; exit 2; }

lock="$METADATA/substrate-restructure.lock"
mkdir -p "$METADATA" || exit 2
if ! mkdir "$lock" 2>/dev/null; then
    printf 'restructure blocked: another restructure owns %s\n' "$lock" >&2
    exit 2
fi
trap 'rmdir "$lock" 2>/dev/null || true' EXIT HUP INT TERM

resolve_change() {
    local rev="$1" resolved
    resolved=$(jj log -r "$rev" --no-graph -T 'change_id ++ "\n"' 2>/dev/null) || return 1
    [ "$(printf '%s\n' "$resolved" | grep -c .)" -eq 1 ] || return 1
    printf '%s\n' "$resolved" | grep .
}
allowed_change() {
    local change="$1" entry
    for entry in "${allow_changes[@]}"; do
        [ "$entry" = "$change" ] && return 0
    done
    return 1
}

target_change=$(resolve_change "$revision") \
    || { printf 'restructure blocked: revision does not resolve to exactly one commit: %s\n' "$revision" >&2; exit 2; }
allowed_change "$target_change" \
    || { printf 'restructure blocked: %s is not an agent session-authored commit\n' "$revision" >&2; exit 2; }

pending_before=$(jj diff --name-only 2>/dev/null | LC_ALL=C sort)
tip_before=$(jj log -r @ --no-graph -T 'commit_id' 2>/dev/null)
op_before=$(jj op log -n 1 --no-graph -T 'id.short(64)' 2>/dev/null)
[ -n "$tip_before" ] && [ -n "$op_before" ] \
    || { printf 'restructure blocked: cannot capture the current operation state\n' >&2; exit 2; }

rollback() {
    jj op restore "$op_before" >/dev/null 2>&1 || true
}
fail_op() {
    rollback
    printf 'restructure failed: %s; repository restored to operation %s\n' "$1" "${op_before:0:12}" >&2
    exit 1
}

new_changes=()
case "$op" in
    split)
        [ "${#normalized[@]}" -gt 0 ] || { printf 'restructure blocked: split requires --path\n' >&2; exit 2; }
        children_before=$(jj log -r "children($target_change)" --no-graph -T 'change_id ++ "\n"' 2>/dev/null | LC_ALL=C sort)
        if ! split_output=$(jj split -r "$target_change" -m "$message" -- "${normalized[@]}" 2>&1); then
            printf '%s\n' "$split_output" >&2
            fail_op "jj split rejected the transaction"
        fi
        children_after=$(jj log -r "children($target_change)" --no-graph -T 'change_id ++ "\n"' 2>/dev/null | LC_ALL=C sort)
        remainder=$(LC_ALL=C comm -13 <(printf '%s\n' "$children_before") <(printf '%s\n' "$children_after") | grep . || true)
        [ "$(printf '%s\n' "$remainder" | grep -c .)" -eq 1 ] \
            || fail_op "could not identify the remainder commit"
        if [ -n "$message2" ] && ! jj describe -r "$remainder" -m "$message2" >/dev/null 2>&1; then
            fail_op "jj describe rejected the remainder message"
        fi
        new_changes+=("$remainder")
        ;;
    describe)
        if ! describe_output=$(jj describe -r "$target_change" -m "$message" 2>&1); then
            printf '%s\n' "$describe_output" >&2
            fail_op "jj describe rejected the transaction"
        fi
        ;;
    squash)
        [ -n "$into" ] || { printf 'restructure blocked: squash requires --into\n' >&2; exit 2; }
        dest_change=$(resolve_change "$into") \
            || { printf 'restructure blocked: --into does not resolve to exactly one commit: %s\n' "$into" >&2; exit 2; }
        allowed_change "$dest_change" \
            || { printf 'restructure blocked: %s is not an agent session-authored commit\n' "$into" >&2; exit 2; }
        [ "$dest_change" != "$target_change" ] \
            || { printf 'restructure blocked: squash source and destination are the same commit\n' >&2; exit 2; }
        if ! squash_output=$(jj squash --from "$target_change" --into "$dest_change" -m "$message" 2>&1); then
            printf '%s\n' "$squash_output" >&2
            fail_op "jj squash rejected the transaction"
        fi
        ;;
esac

[ -z "$(jj log -r 'conflicts()' --no-graph -T 'change_id ++ "\n"' 2>/dev/null)" ] \
    || fail_op "the operation produced conflicts"
pending_after=$(jj diff --name-only 2>/dev/null | LC_ALL=C sort)
[ "$pending_before" = "$pending_after" ] \
    || fail_op "pending working-copy paths changed"
[ -z "$(jj diff --from "$tip_before" --to @ --name-only 2>/dev/null)" ] \
    || fail_op "the working-copy tree changed"

new_revision=$(jj log -r @- --no-graph -T 'commit_id' 2>/dev/null)
target_commit=$(jj log -r "$target_change" --no-graph -T 'commit_id' 2>/dev/null || printf 'abandoned')
if [ "${#new_changes[@]}" -gt 0 ]; then
    new_json=$(printf '%s\n' "${new_changes[@]}" | jq -Rn '[inputs | select(length > 0)]' | jq -c .)
else
    new_json='[]'
fi
receipt=$(jq -cn --arg op "$op" --arg change "$target_change" --arg commit "$target_commit" \
    --arg fromOperation "$op_before" --arg revision "$new_revision" \
    --argjson newChangeIds "$new_json" \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{operation:"restructure",op:$op,changeId:$change,commit:$commit,newChangeIds:$newChangeIds,revision:$revision,fromOperation:$fromOperation,vcs:"jj",noPush:true,at:$at,status:"restructured"}') \
    || { printf 'restructure incomplete: receipt serialization failed\n' >&2; exit 1; }
receipt_dir="$METADATA/substrate"
mkdir -p "$receipt_dir" || exit 1
staged=$(mktemp "$receipt_dir/restructure-receipt.json.XXXXXX") || exit 1
if ! printf '%s\n' "$receipt" > "$staged" || ! chmod 600 "$staged" \
    || ! mv -f "$staged" "$receipt_dir/restructure-receipt.json"; then
    rm -f "$staged"
    printf 'restructure incomplete: receipt write failed\n' >&2
    exit 1
fi

if [ -n "$session" ] && [ -n "$STATE" ]; then
    entries=$(jq -c '.observed.entries // {}' "$STATE")
    fingerprint=$(jq -cnS --arg revision "$new_revision" --argjson entries "$entries" \
        '{revision:$revision,entries:$entries}' | sha256sum | cut -d ' ' -f 1)
    next=$(jq -c --arg revision "$new_revision" --arg fingerprint "$fingerprint" \
        --argjson new "$new_json" '
        .observed.revision = $revision
        | .observed.fingerprint = $fingerprint
        | .initial.revision = $revision
        | .completedCommit = $revision
        | .sessionChanges = (((.sessionChanges // []) + $new) | unique)' "$STATE")
    session_staged=$(mktemp "$STATE.XXXXXX") || exit 1
    if ! printf '%s\n' "$next" > "$session_staged" || ! chmod 600 "$session_staged" \
        || ! mv -f "$session_staged" "$STATE"; then
        rm -f "$session_staged"
        printf 'restructure incomplete: session state update failed\n' >&2
        exit 1
    fi
fi

if [ "$json" -eq 1 ]; then
    printf '%s\n' "$receipt"
else
    printf 'restructure complete: %s %s (undo with: jj op restore %s)\n' "$op" "$target_change" "${op_before:0:12}"
fi
