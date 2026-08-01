#!/usr/bin/env bash
# Firing battery for the jj workflow hooks: block what they must, allow the
# workflow itself, and stay silent in plain git repos — the case a jj-side
# test never exercises and the one that would break every git-only adopter.
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'jj-hooks-test FAIL: %s\n' "$1" >&2; exit 1; }

probe() {
    printf '{"tool_input": {"command": "%s"}, "description": "commit with git add polluting the raw json"}' "$1" \
        | bash "$2"
}

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/jj-repo/.substrate/hooks" "$T/jj-repo/.jj" "$T/git-repo/.substrate/hooks"
for repo in jj-repo git-repo; do
    cp "$KIT_ROOT/core/hooks/enforce-jj.sh" "$KIT_ROOT/core/hooks/enforce-conventional-commits.sh" "$T/$repo/.substrate/hooks/"
done
EJ="$T/jj-repo/.substrate/hooks/enforce-jj.sh"
EC="$T/jj-repo/.substrate/hooks/enforce-conventional-commits.sh"

probe 'git commit -m x' "$EJ" 2>/dev/null; [ $? -eq 2 ] || fail "git commit not blocked in jj repo"
probe 'git push origin main' "$EJ" 2>/dev/null; [ $? -eq 2 ] || fail "git push not blocked in jj repo"
probe 'jj git push' "$EJ"; [ $? -eq 0 ] || fail "jj git push wrongly blocked"
probe 'git status --short' "$EJ"; [ $? -eq 0 ] || fail "read-only git wrongly blocked"
probe 'jj  git push' "$EJ"; [ $? -eq 0 ] || fail "double-space jj git push wrongly blocked"
probe 'git push origin v1.2.3' "$EJ"; [ $? -eq 0 ] || fail "release tag push wrongly blocked"

probe 'jj commit -m wip' "$EC" 2>/dev/null; [ $? -eq 2 ] || fail "non-conventional message not blocked"
probe 'jj commit -m "feat: x"' "$EC"; [ $? -eq 0 ] || fail "conventional message wrongly blocked"
probe 'jj commit' "$EC"; [ $? -eq 0 ] || fail "editor-driven commit wrongly blocked"

GJ="$T/git-repo/.substrate/hooks/enforce-jj.sh"
GC="$T/git-repo/.substrate/hooks/enforce-conventional-commits.sh"
probe 'git commit -m x' "$GJ"; [ $? -eq 0 ] || fail "git-only repo: git commit wrongly blocked"
probe 'git push origin main' "$GJ"; [ $? -eq 0 ] || fail "git-only repo: git push wrongly blocked"
probe 'jj commit -m wip' "$GC"; [ $? -eq 0 ] || fail "git-only repo: conv guard wrongly active"

printf 'jj-hooks-test: 12 cases green (blocks, allows, git-only bypass)\n'
