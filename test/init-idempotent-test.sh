#!/usr/bin/env bash
# Installer idempotency: a second `substrate init` must not grow the Claude
# hook arrays (the remediation text says "rerun init", so re-runs are a
# supported path) and must preserve repo-owned hooks alongside substrate's.
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# scratch inits must never touch the live user harness (~/.claude, ~/.omp)
export SUBSTRATE_NO_USER_HARNESS=1

fail() { printf 'init-idempotent-test FAIL: %s\n' "$1" >&2; exit 1; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
git -C "$T" init -q .
git -C "$T" config user.email substrate@localhost
git -C "$T" config user.name substrate
cd "$T" || exit 9

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
[ "$(grep -c '^gate' justfile)" = "1" ] || fail "gate recipe duplicated on re-run"

chmod 644 .claude/settings.json 2>/dev/null
T2=$(mktemp -d)
(
    cd "$T2" || exit 9
    git init -q .
    git config user.email substrate@localhost
    git config user.name substrate
    printf 'gate:\n    ./my-own-gate.sh\n' > justfile
    if env -u CI "$KIT_ROOT/bin/substrate" init --profile shell >/dev/null 2>&1; then
        exit 10
    fi
    grep -q 'my-own-gate.sh' justfile || exit 11
    [ "$(grep -c '^gate' justfile)" = "1" ] || exit 12
)
case $? in
    10) fail "init exited 0 while refusing to wire an owned gate recipe" ;;
    11) fail "init clobbered a repo-owned gate recipe" ;;
    12) fail "init appended a duplicate gate recipe (breaks just parsing)" ;;
    0) ;;
    *) fail "owned-recipe fixture setup failed" ;;
esac
rm -rf "$T2"

chmod 444 .claude/settings.json
env -u CI "$KIT_ROOT/bin/substrate" init --profile shell >/dev/null 2>&1 \
    || fail "init could not atomically synchronize locked settings"
[ "$(stat -c '%a' .claude/settings.json)" = "444" ] \
    || fail "init changed locked settings mode"
grep -q 'my-own-hook.sh' .claude/settings.json \
    || fail "atomic settings synchronization dropped repo-owned hooks"
chmod 644 .claude/settings.json

printf 'init-idempotent-test: hooks stable at %s groups, locked-settings sync is atomic\n' "$count1"
