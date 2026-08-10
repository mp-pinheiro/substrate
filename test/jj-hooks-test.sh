#!/usr/bin/env bash
# Firing battery for the jj workflow hooks: block what they must, allow the
# workflow itself, and stay silent in plain git repos — the case a jj-side
# test never exercises and the one that would break every git-only adopter.
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KIT_ROOT

fail() { printf 'jj-hooks-test FAIL: %s\n' "$1" >&2; exit 1; }

probe() {
    printf '{"tool_input": {"command": "%s"}, "description": "commit with git add polluting the raw json"}' "$1" \
        | ( cd "$2" && substrate-engine hook "$3" )
}

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/jj-repo/.jj" "$T/git-repo"

probe 'git commit -m x' "$T/jj-repo" enforce-jj 2>/dev/null; [ $? -eq 2 ] || fail "git commit not blocked in jj repo"
probe 'git push origin main' "$T/jj-repo" enforce-jj 2>/dev/null; [ $? -eq 2 ] || fail "git push not blocked in jj repo"
probe 'jj git push' "$T/jj-repo" enforce-jj; [ $? -eq 0 ] || fail "jj git push wrongly blocked"
probe 'git status --short' "$T/jj-repo" enforce-jj; [ $? -eq 0 ] || fail "read-only git wrongly blocked"
probe 'jj  git push' "$T/jj-repo" enforce-jj; [ $? -eq 0 ] || fail "double-space jj git push wrongly blocked"
probe 'git push origin v1.2.3' "$T/jj-repo" enforce-jj; [ $? -eq 0 ] || fail "release tag push wrongly blocked"

probe 'jj commit -m wip' "$T/jj-repo" enforce-conventional-commits 2>/dev/null; [ $? -eq 2 ] || fail "non-conventional message not blocked"
probe 'jj commit -m "feat: x"' "$T/jj-repo" enforce-conventional-commits; [ $? -eq 0 ] || fail "conventional message wrongly blocked"
probe 'jj commit' "$T/jj-repo" enforce-conventional-commits; [ $? -eq 0 ] || fail "editor-driven commit wrongly blocked"

probe 'git commit -m x' "$T/git-repo" enforce-jj; [ $? -eq 0 ] || fail "git-only repo: git commit wrongly blocked"
probe 'git push origin main' "$T/git-repo" enforce-jj; [ $? -eq 0 ] || fail "git-only repo: git push wrongly blocked"
probe 'jj commit -m wip' "$T/git-repo" enforce-conventional-commits; [ $? -eq 0 ] || fail "git-only repo: conv guard wrongly active"

printf 'jj-hooks-test: 12 cases green (blocks, allows, git-only bypass)\n'
