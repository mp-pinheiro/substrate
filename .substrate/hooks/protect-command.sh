#!/usr/bin/env bash
# PreToolUse (Bash): block direct commits and shell-level governance tampering.
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBSTRATE_DIR="$(cd "$HOOK_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SUBSTRATE_DIR/.." && pwd)"
CONFIG="$REPO_ROOT/substrate.json"

command -v jq >/dev/null 2>&1 || {
    printf 'blocked: jq is required to inspect Bash commands safely\n' >&2
    exit 2
}
input=$(cat)
cmd=$(jq -r '.tool_input.command // .command // empty' <<< "$input") \
    || { printf 'blocked: malformed Bash tool payload\n' >&2; exit 2; }
[ -n "$cmd" ] || exit 0
if printf '%s' "$cmd" | grep -Eq '(^|[[:space:]/])substrate[[:space:]]+verify([[:space:];&|>]|$)' \
    && ! printf '%s' "$cmd" | grep -Eq '^[[:space:]]*([^[:space:]]*/)?substrate[[:space:]]+verify[[:space:]]*$'; then
    printf 'BLOCKED: run substrate verify directly and unmodified; pipes, redirects, and chained commands can hide a failing verdict\n' >&2
    exit 2
fi

if printf '%s' "$cmd" | grep -Eq '(^|[;&|(`][[:space:]]*)(jj[[:space:]]+(commit|describe|squash)|git[[:space:]]+commit)([[:space:]"\\]|$)'; then
    printf 'BLOCKED: commits must use the Substrate checkpoint transaction after direct verification; do not run jj commit, jj describe, jj squash, or git commit directly\n' >&2
    exit 2
fi
if printf '%s' "$cmd" | grep -Eq '(^|[;&|(`][[:space:]]*)[^[:space:]]*\.substrate/checkpoint\.sh([[:space:]"\\]|$)'; then
    printf 'BLOCKED: invoke checkpoints through the harness lifecycle, not the vendored script directly\n' >&2
    exit 2
fi
if printf '%s' "$cmd" | grep -Eq '(^|[;&|][[:space:]]*|[[:space:]])substrate[[:space:]]+checkpoint([[:space:]]|$)'; then
    session=$(jq -r '.session_id // empty' <<< "$input")
    case "$session" in
        ''|*[!A-Za-z0-9._-]*)
            printf 'BLOCKED: Claude checkpoint command has no valid lifecycle session\n' >&2
            exit 2 ;;
    esac
    if ! printf '%s' "$cmd" | grep -Eq -- "--session([=[:space:]])['\"]?${session}(['\"[:space:]]|$)"; then
        printf 'BLOCKED: Claude checkpoint command must carry its current lifecycle session id\n' >&2
        exit 2
    fi
fi
if printf '%s' "$cmd" | grep -Eq '(^|[;&|][[:space:]]*|[[:space:]])substrate[[:space:]]+restructure([[:space:]]|$)'; then
    session=$(jq -r '.session_id // empty' <<< "$input")
    case "$session" in
        ''|*[!A-Za-z0-9._-]*)
            printf 'BLOCKED: Claude restructure command has no valid lifecycle session\n' >&2
            exit 2 ;;
    esac
    if ! printf '%s' "$cmd" | grep -Eq -- "--session([=[:space:]])['\"]?${session}(['\"[:space:]]|$)"; then
        printf 'BLOCKED: Claude restructure command must carry its current lifecycle session id\n' >&2
        exit 2
    fi
fi
if printf '%s' "$cmd" | grep -Eq '(^|[;&|(`][[:space:]]*)[^[:space:]]*\.substrate/restructure\.sh([[:space:]"\\]|$)'; then
    printf 'BLOCKED: invoke restructures through the harness lifecycle, not the vendored script directly\n' >&2
    exit 2
fi
if printf '%s' "$cmd" | grep -Eq '(^|[[:space:]])(--update-baseline|--tighten|--accept-regression)([[:space:]]|$)'; then
    printf 'BLOCKED: baseline mutations are checkpoint-owned; initial debt or regressions require the user to run the explicit baseline command\n' >&2
    exit 2
fi

if [ -f "$CONFIG" ] && ! jq -e . "$CONFIG" >/dev/null 2>&1; then
    printf 'blocked: substrate.json is corrupt — fix it before running mutating Bash commands\n' >&2
    exit 2
fi

mutator=0
if printf '%s' "$cmd" | grep -Eq '(^|[;&|][[:space:]]*|[[:space:]])(rm|mv|cp|install|chmod|chown|ln|touch|truncate|tee|dd)([[:space:]]|$)|perl([^;&|]*[[:space:]])-[^[:space:]]*i'; then
    mutator=1
fi

block_if_named() {
    local needle="$1" label="$2"
    [ -n "$needle" ] || return 0
    if [ "$mutator" -eq 1 ] && printf '%s' "$cmd" | grep -Fq -- "$needle"; then
        printf 'BLOCKED: Bash command can mutate governed path %s (%s); use the protected workflow instead\n' "$needle" "$label" >&2
        exit 2
    fi
    if printf '%s' "$cmd" | grep -Eq ">>?[[:space:]]*['\"]?[^;&|]*${needle//./\\.}"; then
        printf 'BLOCKED: shell redirection targets governed path %s (%s)\n' "$needle" "$label" >&2
        exit 2
    fi
    if printf '%s' "$cmd" | grep -Eq "[A-Za-z_][A-Za-z0-9_]*=['\"]?[^;&|]*${needle//./\\.}" \
        && printf '%s' "$cmd" | grep -Eq '>>?[^;&|]*\$|tee[[:space:]][^;&|]*\$'; then
        printf 'BLOCKED: indirect shell write resolves to governed path %s (%s)\n' "$needle" "$label" >&2
        exit 2
    fi
}

block_if_named 'substrate-baseline.json' baseline
block_if_named '.substrate' 'vendored engine'
block_if_named 'CLAUDE.md' governance
if [ -f "$CONFIG" ]; then
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        literal="${path%%\**}"
        literal="${literal%%\?*}"
        literal="${literal%%\[*}"
        [ -n "$literal" ] && block_if_named "$literal" protected_paths
    done < <(jq -r '(.protected_paths // [])[]' "$CONFIG")
    while IFS= read -r path; do
        [ -n "$path" ] && block_if_named "$path" contract
    done < <(jq -r '(.contracts // [])[] | (.paths // [])[]' "$CONFIG")
fi
exit 0
