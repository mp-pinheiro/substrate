#!/usr/bin/env bash
# jj push alias target: validate an exact receipt or run the gate, then pass
# the caller's arguments through to jj git push. Invocation remains explicit.
set -uo pipefail

SUBSTRATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SUBSTRATE_DIR/.." && pwd)"
cd "$REPO_ROOT" || exit 2

if ! "$SUBSTRATE_DIR/push-gate.sh"; then
    exit 2
fi
if [ "$#" -gt 0 ]; then
    exec jj git push "$@"
fi

receipt_path=$(gate_receipt_path) || { printf 'push blocked: cannot locate checkpoint receipt\n' >&2; exit 2; }
[ -f "$receipt_path" ] || { printf 'push blocked: no reusable checkpoint receipt\n' >&2; exit 2; }
commit=$(jq -r '.commit // empty' "$receipt_path" 2>/dev/null) || commit=""
bookmark=$(jq -r '.publicationBookmark // empty' "$receipt_path" 2>/dev/null) || bookmark=""
if [ -z "$commit" ]; then
    printf 'push blocked: receipt has no checkpoint commit\n' >&2
    exit 2
fi
if [ -n "$bookmark" ]; then
    actual=$(jj log -r "$bookmark" --no-graph -T commit_id 2>/dev/null) || actual=""
    if [ "$actual" != "$commit" ]; then
        printf 'push blocked: receipt bookmark %s no longer points to %s\n' "$bookmark" "$commit" >&2
        exit 2
    fi
else
    candidates_file=$(mktemp) || { printf 'push blocked: cannot infer publication bookmark\n' >&2; exit 2; }
    while IFS=$'\t' read -r name rev; do
        [ "$rev" = "$commit" ] && printf '%s\n' "$name" >> "$candidates_file"
    done < <(jj bookmark list --template 'name ++ "\t" ++ commit_id ++ "\n"' 2>/dev/null)
    mapfile -t candidates < "$candidates_file"
    rm -f "$candidates_file"
    if [ "${#candidates[@]}" -eq 0 ]; then
        printf 'push blocked: receipt has no publication bookmark and no local bookmark at %s\n' "$commit" >&2
        exit 2
    fi
    if [ "${#candidates[@]}" -gt 1 ]; then
        for candidate in "${candidates[@]}"; do
            case "$candidate" in
                main|master) preferred+=("$candidate") ;;
            esac
        done
        if [ "${#preferred[@]}" -eq 1 ]; then
            candidates=("${preferred[0]}")
        fi
    fi
    if [ "${#candidates[@]}" -gt 1 ]; then
        printf 'push blocked: receipt bookmark is ambiguous at %s: %s\n' "$commit" "${candidates[*]}" >&2
        exit 2
    fi
    bookmark=${candidates[0]}
fi
exec jj git push --bookmark "$bookmark"
