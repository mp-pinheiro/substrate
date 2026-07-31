#!/usr/bin/env bash
# PreToolUse (Bash): a push seals work on the remote, so the gate must pass first.
# Matches this repo's own push (`jj git push` / `git push`), not `-R <other>` forms.
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBSTRATE_DIR="$(cd "$HOOK_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SUBSTRATE_DIR/.." && pwd)"
CONFIG="$REPO_ROOT/substrate.json"

input=$(cat)
cmd=$(jq -r '.tool_input.command // empty' <<< "$input")
case "$cmd" in
    *"jj git push"*|*"git push"*) ;;
    *) exit 0 ;;
esac
case "$cmd" in
    *"-R "*) exit 0 ;;
esac

if [ -f "$CONFIG" ] && [ "$(jq -r '.push_gate // true' "$CONFIG" 2>/dev/null)" = "false" ]; then
    exit 0
fi

if ! output=$("$SUBSTRATE_DIR/gate.sh" 2>&1); then
    printf '%s\n' "$output" >&2
    echo "push blocked: fix the failing gate checks first" >&2
    exit 2
fi
exit 0
