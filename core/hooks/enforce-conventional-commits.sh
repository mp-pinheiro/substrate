#!/usr/bin/env bash
# PreToolUse (Bash): Conventional Commits on jj commit/describe/squash inline
# messages — jj does not run git's commit-msg hook, so this is the enforcement
# point. No-op outside jj repos. Fails open without jq (no false blocks).
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HOOK_DIR/../.." && pwd)"
SUBSTRATE_DIR="$(cd "$HOOK_DIR/.." && pwd)"
# shellcheck source=../engine-shim.sh
source "$SUBSTRATE_DIR/engine-shim.sh"
substrate_engine_exec enforce-conventional-commits "$@"
[ -d "$REPO_ROOT/.jj" ] || exit 0

command -v jq >/dev/null 2>&1 || exit 0
cmd=$(jq -r '.tool_input.command // .command // empty' 2>/dev/null)
[ -n "$cmd" ] || exit 0

printf '%s' "$cmd" | grep -Eq '(^|[;&|(`][[:space:]]*)jj[[:space:]]+(commit|describe|squash)([[:space:]]|$)' || exit 0
printf '%s' "$cmd" | grep -Eq '(-m|--message)([[:space:]=])' || exit 0

conv='(-m|--message)[[:space:]=]+["'"'"']?(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([^)]+\))?!?:[[:space:]]'
if ! printf '%s' "$cmd" | grep -Eq "$conv"; then
    echo "BLOCKED: commit message must follow Conventional Commits — 'type(scope): subject'. Types: feat, fix, docs, style, refactor, perf, test, build, ci, chore, revert (append ! for breaking). Example: jj commit -m 'feat(auth): add login'." >&2
    exit 2
fi
exit 0
