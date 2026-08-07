#!/usr/bin/env bash
# PreToolUse (Bash): in a jj-managed repo (colocated .jj, git HEAD detached on
# purpose) every VCS write goes through jj — mutating git is blocked, read-only
# git and release tags stay allowed. No-op in plain git repos: the guard is
# runtime, not install-time, so the hook ships safely to every consumer.
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HOOK_DIR/../.." && pwd)"
SUBSTRATE_DIR="$(cd "$HOOK_DIR/.." && pwd)"
# shellcheck source=../engine-shim.sh
source "$SUBSTRATE_DIR/engine-shim.sh" 2>/dev/null || true
declare -F substrate_engine_exec >/dev/null 2>&1 && substrate_engine_exec enforce-jj "$@"
[ -d "$REPO_ROOT/.jj" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# jq parses the command field only (raw-JSON grep also matches descriptions,
# diverging from the omp mirror); gsub kills `jj git` sans PCRE lookbehind
cmd=$(jq -r '(.tool_input.command // .command // empty) | gsub("jj\\s+git"; "JJ_GIT")' 2>/dev/null)
[ -n "$cmd" ] || exit 0

if printf '%s' "$cmd" | grep -Eq 'git[[:space:]]+(commit|add|rebase|merge|reset|restore|switch|checkout|cherry-pick|revert|stash|clean|am|apply)([[:space:]"\\]|$)'; then
    echo "BLOCKED: this repo is jj-managed — use jj, not git, for VCS changes: 'jj commit -m', 'jj tug', 'jj git push' (see docs/jj-workflow.md). Read-only git (log/status/diff/show) and release 'git tag' are fine." >&2
    exit 2
fi

if printf '%s' "$cmd" | grep -Eq 'git[[:space:]]+push'; then
    if printf '%s' "$cmd" | grep -Eq '(--tags|[[:space:]]v[0-9])'; then
        exit 0
    fi
    echo "BLOCKED: use 'jj git push', not 'git push', in this jj-managed repo (release tags are the exception: 'git push origin vX.Y.Z'). See docs/jj-workflow.md." >&2
    exit 2
fi

exit 0
