#!/usr/bin/env bash
# Installer idempotency: a second `substrate init` must not grow the Claude
# hook arrays (the remediation text says "rerun init", so re-runs are a
# supported path) and must preserve repo-owned hooks alongside substrate's.
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'init-idempotent-test FAIL: %s\n' "$1" >&2; exit 1; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
cd "$T" || exit 9
git init -q .
git config user.email substrate@localhost
git config user.name substrate

mkdir -p .claude
printf '{"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "bash my-own-hook.sh"}]}]}}\n' > .claude/settings.json

env -u CI "$KIT_ROOT/bin/substrate" init --profile shell >/dev/null 2>&1 || fail "first init failed"
count1=$(jq '[(.hooks.PreToolUse // [])[], (.hooks.PostToolUse // [])[]] | length' .claude/settings.json)
grep -q 'my-own-hook.sh' .claude/settings.json || fail "repo-owned hook dropped by first init"
grep -q '.substrate/hooks/protect-paths.sh' .claude/settings.json || fail "substrate hooks not wired"

env -u CI "$KIT_ROOT/bin/substrate" init --profile shell >/dev/null 2>&1
count2=$(jq '[(.hooks.PreToolUse // [])[], (.hooks.PostToolUse // [])[]] | length' .claude/settings.json)
[ "$count1" = "$count2" ] || fail "hook groups grew on re-run ($count1 -> $count2)"
grep -q 'my-own-hook.sh' .claude/settings.json || fail "repo-owned hook dropped by re-run"

printf 'init-idempotent-test: hooks stable at %s groups across re-runs\n' "$count1"
