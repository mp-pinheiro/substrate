#!/usr/bin/env bash
# PreToolUse (Bash): a push seals work on the remote, so the gate must pass first.
# Matches this repo's own push (`jj git push` / `git push`), not `-R <other>` forms.
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBSTRATE_DIR="$(cd "$HOOK_DIR/.." && pwd)"
# shellcheck source=../engine-shim.sh
source "$SUBSTRATE_DIR/engine-shim.sh" 2>/dev/null || true
declare -F substrate_engine_exec >/dev/null 2>&1 && substrate_engine_exec gate-before-push "$@"

input=$(cat)
cmd=$(jq -r '.tool_input.command // empty' <<< "$input")
case "$cmd" in
    *"jj git push"*|*"git push"*) ;;
    *) exit 0 ;;
esac
case "$cmd" in
    *"-R "*) exit 0 ;;
esac


if ! output=$("$SUBSTRATE_DIR/push-gate.sh" 2>&1); then
    printf '%s\n' "$output" >&2
    echo "push blocked: fix the failing gate checks first" >&2
    exit 2
fi
exit 0
