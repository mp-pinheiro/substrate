#!/usr/bin/env bash
# Claude lifecycle ownership ledger and completion guard.
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBSTRATE_DIR="$(cd "$HOOK_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SUBSTRATE_DIR/.." && pwd)"
cd "$REPO_ROOT" || exit 2
# shellcheck source=../maintenance-lib.sh
source "$SUBSTRATE_DIR/maintenance-lib.sh"

action="${1:-}"
metadata_dir() {
    local git_dir
    if git_dir=$(git rev-parse --git-common-dir 2>/dev/null); then
        case "$git_dir" in
            /*) printf '%s\n' "$git_dir" ;;
            *) printf '%s\n' "$REPO_ROOT/$git_dir" ;;
        esac
    elif [ -d .jj ]; then
        printf '%s\n' "$REPO_ROOT/.jj"
    else
        return 1
    fi
}
METADATA=$(metadata_dir) || exit 0
STATE_DIR="$METADATA/substrate/agent-sessions"
mkdir -p "$STATE_DIR" || { printf 'substrate lifecycle: cannot create state directory\n' >&2; exit 2; }

valid_session() {
    case "$1" in
        ''|*[!A-Za-z0-9._-]*) return 1 ;;
        *) return 0 ;;
    esac
}
state_path() {
    valid_session "$1" || return 1
    printf '%s/%s.json\n' "$STATE_DIR" "$1"
}
write_state() {
    local path="$1" value="$2" staged
    staged=$(mktemp "$path.XXXXXX") || return 1
    if printf '%s\n' "$value" > "$staged" && chmod 600 "$staged" && mv -f "$staged" "$path"; then
        return 0
    fi
    rm -f "$staged"
    return 1
}

snapshot() {
    local revision_result revision_error="" paths_file entries_file entries fingerprint path value error=""
    paths_file=$(mktemp)
    entries_file=$(mktemp)
    if [ -e .jj ] && command -v jj >/dev/null 2>&1; then
        revision_result=$(jj log -r @- --no-graph -T 'commit_id' 2>&1) || revision_error="$revision_result"
        jj diff --name-only 2>"$paths_file.error" | LC_ALL=C sort -u > "$paths_file" \
            || error=$(cat "$paths_file.error")
    else
        revision_result=$(git rev-parse HEAD 2>&1) || revision_error="$revision_result"
        {
            git diff --name-only --diff-filter=ACDMRTUXB HEAD --
            git ls-files --others --exclude-standard
        } 2>"$paths_file.error" | LC_ALL=C sort -u > "$paths_file" \
            || error=$(cat "$paths_file.error")
    fi
    rm -f "$paths_file.error"
    [ -n "$revision_error" ] && error="$revision_error"
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        case "$path" in
            *$'\t'*|*$'\n'*|/*|../*|*/../*) error="unsafe changed path: $path"; break ;;
        esac
        if [ -L "$path" ]; then
            value="symlink:$(readlink "$path" 2>/dev/null || printf unreadable)"
        elif [ -f "$path" ]; then
            value="file:$(sha256sum "$path" | cut -d ' ' -f 1)"
        elif [ -e "$path" ]; then
            value="unreadable"
        else
            value="deleted"
        fi
        jq -cn --arg path "$path" --arg value "$value" '{($path):$value}' >> "$entries_file"
    done < "$paths_file"
    entries=$(jq -sc 'add // {}' "$entries_file") || error="snapshot serialization failed"
    fingerprint=$(jq -cnS --arg revision "${revision_result:-}" --argjson entries "$entries" \
        '{revision:$revision,entries:$entries}' | sha256sum | cut -d ' ' -f 1)
    jq -cn --arg revision "${revision_result:-}" --argjson entries "$entries" \
        --arg fingerprint "$fingerprint" --arg error "$error" \
        '{revision:$revision,entries:$entries,fingerprint:$fingerprint,error:(if $error == "" then null else $error end)}'
    rm -f "$paths_file" "$entries_file"
}

payload=""
session=""
if [ "$action" = start ] || [ "$action" = observe ] || [ "$action" = stop ] || [ "$action" = end ]; then
    payload=$(cat)
    session=$(jq -r '.session_id // empty' <<< "$payload") \
        || { printf 'substrate lifecycle: malformed hook payload\n' >&2; exit 2; }
else
    session="${2:-}"
fi
valid_session "$session" || { printf 'substrate lifecycle: invalid session id\n' >&2; exit 2; }
STATE=$(state_path "$session") || exit 2

case "$action" in
    start)
        report_warning=""
        if [ -x "$SUBSTRATE_DIR/report.sh" ]; then
            report_warning=$("$SUBSTRATE_DIR/report.sh" --refresh 2>&1 >/dev/null)
        fi
        current=$(snapshot)
        state=$(jq -cn --arg session "$session" --arg root "$REPO_ROOT" --argjson current "$current" \
            '{session:$session,repoRoot:$root,initial:$current,observed:$current,ownedPaths:[],trackingError:$current.error,stopBlocked:false,completedCommit:null}')
        write_state "$STATE" "$state" || { printf 'substrate lifecycle: state write failed\n' >&2; exit 2; }
        context="Substrate lifecycle active. After direct verification, checkpoint with: substrate checkpoint --session $session --message 'type(scope): subject'. Never commit or push directly."
        [ -z "$report_warning" ] || context="$context $report_warning"
        jq -cn --arg context "$context" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$context}}'
        ;;
    observe)
        if [ ! -f "$STATE" ]; then
            current=$(snapshot)
            state=$(jq -cn --arg session "$session" --arg root "$REPO_ROOT" --argjson current "$current" \
                '{session:$session,repoRoot:$root,initial:$current,observed:$current,ownedPaths:[],trackingError:"SessionStart ownership state missing",stopBlocked:false,completedCommit:null}')
            write_state "$STATE" "$state" || exit 2
            exit 0
        fi
        state=$(cat "$STATE")
        current=$(snapshot)
        changed=$(jq -cn --argjson before "$(jq '.observed.entries' <<< "$state")" --argjson after "$(jq '.entries' <<< "$current")" '
            (($before | keys) + ($after | keys) | unique)
            | map(select($before[.] != $after[.]))')
        before_revision=$(jq -r '.observed.revision' <<< "$state")
        current_revision=$(jq -r '.revision' <<< "$current")
        maintenance_receipt="$METADATA/substrate/maintenance-receipt.json"
        reconcile='.observed = $current
            | .initial.entries = (.initial.entries | with_entries(select(.key as $k | ($current.entries | has($k)))))
            | .initial.revision = $current.revision
            | .initial.entries as $init
            | .ownedPaths = (((.ownedPaths + $changed) | unique)
                | map(select(. as $p | ($current.entries | has($p)) and (($init | has($p)) | not))))'
        if [ "$before_revision" != "$current_revision" ] \
            && maintenance_repository_receipt_matches "$maintenance_receipt" \
            && jq -e --arg from "$before_revision" --arg to "$current_revision" '
                (.operation == "init" or .operation == "bootstrap" or .operation == "update")
                and .noPush == true
                and .repository.status == "committed"
                and .repository.fromRevision == $from
                and .repository.toRevision == $to
                and .repository.commit == $to' "$maintenance_receipt" >/dev/null 2>&1; then
            next=$(jq -c --argjson current "$current" --argjson changed "$changed" "$reconcile"'
                | .trackingError = null
                | .driftNotice = null
                | .stopBlocked = false
                | .completedCommit = $current.revision' <<< "$state")
            write_state "$STATE" "$next" || exit 2
            exit 0
        fi
        next=$(jq -c --argjson current "$current" --argjson changed "$changed" "$reconcile"'
            | .stopBlocked = (if ($changed | length) > 0 then false else .stopBlocked end)
            | .completedCommit = (if ($changed | length) > 0 then null else .completedCommit end)
            | .trackingError = (if $current.error != null then $current.error else null end)' <<< "$state")
        if [ "$before_revision" != "$current_revision" ]; then
            next=$(jq -c '.driftNotice = "repository revision changed outside the checkpoint transaction; ownership re-baselined"' <<< "$next")
        fi
        write_state "$STATE" "$next" || exit 2
        ;;
    verify)
        [ -f "$STATE" ] || { printf 'checkpoint blocked: Claude ownership state is missing\n' >&2; exit 2; }
        state=$(cat "$STATE")
        [ "$(jq -r '.repoRoot' <<< "$state")" = "$REPO_ROOT" ] \
            || { printf 'checkpoint blocked: ownership state belongs to another repository\n' >&2; exit 2; }
        [ "$(jq -r '.trackingError // empty' <<< "$state")" = "" ] \
            || { printf 'checkpoint blocked: %s\n' "$(jq -r '.trackingError' <<< "$state")" >&2; exit 2; }
        current=$(snapshot)
        [ "$(jq -r '.error // empty' <<< "$current")" = "" ] \
            || { printf 'checkpoint blocked: working-copy inspection failed\n' >&2; exit 2; }
        [ "$(jq -r '.fingerprint' <<< "$current")" = "$(jq -r '.observed.fingerprint' <<< "$state")" ] \
            || { printf 'checkpoint blocked: working copy changed outside an observed Claude tool call\n' >&2; exit 2; }
        paths=$(jq -cn --argjson pending "$(jq '.entries | keys' <<< "$current")" \
            --argjson owned "$(jq '.ownedPaths' <<< "$state")" '$pending - ($pending - $owned)')
        [ "$(jq 'length' <<< "$paths")" -gt 0 ] \
            || { printf 'checkpoint blocked: no pending Claude-owned changes\n' >&2; exit 2; }
        jq -cn --argjson paths "$paths" --arg fingerprint "$(jq -r '.fingerprint' <<< "$current")" \
            '{paths:$paths,fingerprint:$fingerprint}'
        ;;
    complete)
        commit="${3:-}"
        [ -f "$STATE" ] || exit 0
        current=$(snapshot)
        owned_pending=$(jq -cn --argjson pending "$(jq '.entries | keys' <<< "$current")" \
            --argjson owned "$(jq '.ownedPaths' "$STATE")" '$pending - ($pending - $owned)')
        [ "$(jq 'length' <<< "$owned_pending")" -eq 0 ] \
            || { printf 'substrate lifecycle: checkpoint left owned paths pending\n' >&2; exit 2; }
        [ "$(jq -r '.revision' <<< "$current")" = "$commit" ] \
            || { printf 'substrate lifecycle: checkpoint receipt does not match repository revision\n' >&2; exit 2; }
        next=$(jq -c --argjson current "$current" --arg commit "$commit" '
            .observed=$current | .initial=$current | .ownedPaths=[] | .trackingError=null
            | .driftNotice=null | .stopBlocked=false | .completedCommit=$commit' "$STATE")
        if [ -e .jj ] && command -v jj >/dev/null 2>&1; then
            change=$(jj log -r "$commit" --no-graph -T 'change_id' 2>/dev/null)
            [ -z "$change" ] || next=$(jq -c --arg change "$change" \
                '.sessionChanges = (((.sessionChanges // []) + [$change]) | unique)' <<< "$next")
        fi
        write_state "$STATE" "$next" || exit 2
        ;;
    stop)
        [ -f "$STATE" ] || exit 0
        state=$(cat "$STATE")
        current=$(snapshot)
        owned_pending=$(jq -cn --argjson paths "$(jq '.entries | keys' <<< "$current")" \
            --argjson owned "$(jq '.ownedPaths' <<< "$state")" '$paths - ($paths - $owned)')
        completed=$(jq -r '.completedCommit // empty' <<< "$state")
        revision=$(jq -r '.revision' <<< "$current")
        revision_bypass=0
        if [ "$revision" != "$(jq -r '.initial.revision' <<< "$state")" ] && [ "$revision" != "$completed" ]; then
            revision_bypass=1
        fi
        tracking=$(jq -r '.trackingError // empty' <<< "$state")
        current_error=$(jq -r '.error // empty' <<< "$current")
        if [ "$(jq '.ownedPaths | length' <<< "$state")" -gt 0 ] \
            && [ "$(jq -r '.fingerprint' <<< "$current")" != "$(jq -r '.observed.fingerprint' <<< "$state")" ]; then
            tracking="working copy changed outside an observed Claude tool call"
        fi
        if [ -n "$tracking" ] && [ "$(jq '.entries | length' <<< "$current")" -eq 0 ]; then
            tracking=""
        fi
        auto_note=""
        stop_active=$(jq -r '.stop_hook_active // false' <<< "$payload")
        if [ "$(jq 'length' <<< "$owned_pending")" -gt 0 ] && [ -z "$tracking" ] \
            && [ -z "$current_error" ] && [ "$stop_active" != true ]; then
            if auto_output=$("$SUBSTRATE_DIR/checkpoint.sh" --session "$session" \
                --message 'chore(agent): checkpoint owned work at session stop' --json 2>&1); then
                auto_commit=$(printf '%s\n' "$auto_output" | tail -n 1 | jq -r '.commit // empty' 2>/dev/null)
                jq -cn --arg message "Substrate auto-checkpoint ${auto_commit:-unknown} committed agent-owned work. No push performed." \
                    '{systemMessage:$message}'
                exit 0
            fi
            auto_note=" Automatic checkpoint failed: $(printf '%s\n' "$auto_output" | tail -n 1)."
        fi
        if [ "$(jq 'length' <<< "$owned_pending")" -eq 0 ] && [ "$revision_bypass" -eq 0 ] \
            && [ -z "$tracking" ] && [ -z "$current_error" ]; then
            exit 0
        fi
        unowned=$(jq -cn --argjson paths "$(jq '.entries | keys' <<< "$current")" \
            --argjson owned "$(jq '.ownedPaths' <<< "$state")" '$paths - $owned')
        reason="[substrate — completion blocked]"
        [ "$(jq 'length' <<< "$owned_pending")" -eq 0 ] \
            || reason="$reason Agent-owned pending paths: $(jq -r 'join(", ")' <<< "$owned_pending")."
        [ "$(jq 'length' <<< "$unowned")" -eq 0 ] \
            || reason="$reason Unowned pending paths: $(jq -r 'join(", ")' <<< "$unowned")."
        [ "$revision_bypass" -eq 0 ] || reason="$reason Repository revision changed without a checkpoint receipt."
        [ -z "$tracking" ] || reason="$reason Ownership error: $tracking."
        [ -z "$current_error" ] || reason="$reason Inspection error: $current_error."
        reason="$reason$auto_note"
        reason="$reason Run direct verification, then: substrate checkpoint --session $session --message 'type(scope): subject'. Never push."
        already_blocked=$(jq -r '.stopBlocked // false' <<< "$state")
        if [ "$stop_active" = true ] || [ "$already_blocked" = true ]; then
            jq -cn --arg message "$reason" '{systemMessage:$message}'
            exit 0
        fi
        next=$(jq -c '.stopBlocked=true' <<< "$state")
        write_state "$STATE" "$next" || exit 2
        jq -cn --arg reason "$reason" '{decision:"block",reason:$reason}' >&2
        exit 2
        ;;
    end)
        rm -f "$STATE"
        ;;
    *)
        printf 'usage: agent-lifecycle.sh start|observe|verify <session>|complete <session> <commit>|stop|end\n' >&2
        exit 2
        ;;
esac
