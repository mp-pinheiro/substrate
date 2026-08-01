#!/usr/bin/env bash
# User-level Claude hook dispatcher (~/.claude/hooks/): resolves the repo from
# the tool's target path (else the session root), walks up to the vendored
# hook, exits 0 where none exists — safe to register machine-globally.
# Usage: substrate-launch.sh <hook-name>  (stdin payload passes through)
set -uo pipefail

hook="${1:-}"
[ -n "$hook" ] || exit 0
case "$hook" in
    */* | .*) exit 0 ;;
esac

payload=""
[ -t 0 ] || payload=$(cat)

target=""
if [ -n "$payload" ] && command -v jq >/dev/null 2>&1; then
    target=$(printf '%s' "$payload" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null) || target=""
fi

dir=""
if [ -n "$target" ]; then
    dir="$(cd "$(dirname "$target")" 2>/dev/null && pwd)" || dir=""
fi
session="$(cd "${CLAUDE_PROJECT_DIR:-$PWD}" 2>/dev/null && pwd)" || session=""
if [ -z "$dir" ]; then
    dir="$session"
    [ -n "$dir" ] || exit 0
fi

while :; do
    if [ -f "$dir/.substrate/hooks/$hook" ]; then
        # only the session root's settings.json is loaded by Claude — stand
        # down there alone, or a foreign repo's inert wiring would mask us
        if [ "$dir" = "$session" ] && [ -f "$dir/.claude/settings.json" ] \
            && grep -qF ".substrate/hooks/$hook" "$dir/.claude/settings.json" 2>/dev/null; then
            exit 0
        fi
        exec bash "$dir/.substrate/hooks/$hook" <<< "$payload"
    fi
    [ "$dir" = "/" ] && exit 0
    dir="$(dirname "$dir")"
done
