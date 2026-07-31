#!/usr/bin/env bash
# PostToolUse (Write|Edit): the touched file must stay at or below its
# grandfathered comment metric. Exit 2 feeds the report back as blocking feedback.
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBSTRATE_DIR="$(cd "$HOOK_DIR/.." && pwd)"

input=$(cat)
path=$(jq -r '.tool_input.file_path // empty' <<< "$input")
[ -n "$path" ] || exit 0

if ! report=$("$SUBSTRATE_DIR/comment-ratchet.sh" "$path"); then
    printf '%s\n' "$report" >&2
    exit 2
fi
exit 0
