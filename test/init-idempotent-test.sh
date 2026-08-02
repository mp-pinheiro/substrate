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

T3=$(mktemp -d)
(
    cd "$T3" || exit 20
    git init -q .
    git config user.email substrate@localhost
    git config user.name substrate
    mkdir -p .claude/skills/context-pack
    printf '{"repoHook": true}\n' > .claude/settings.json
    printf 'repo-owned skill\n' > .claude/skills/context-pack/SKILL.md
    git add .claude
    git commit -q -m 'chore: seed repo-owned inputs'
    env -u CI "$KIT_ROOT/bin/substrate" init --profile shell >/dev/null 2>&1 || exit 21
    git add -A
    .substrate/gate.sh --update-baseline >/dev/null 2>&1 || exit 22
    git add substrate-baseline.json
    git commit -q -m 'chore: seed substrate'

    staged=$(mktemp)
    jq '.seedableProbe = "preserved"' .claude/settings.json > "$staged" || exit 23
    mv "$staged" .claude/settings.json
    rm .claude/skills/context-pack/SKILL.md
    env -u CI "$KIT_ROOT/bin/substrate" init --profile shell >/dev/null 2>&1 || exit 24
    jq -e '.seedableProbe == "preserved"' .claude/settings.json >/dev/null || exit 25
    [ ! -e .claude/skills/context-pack/SKILL.md ] || exit 26
    receipt=.git/substrate/maintenance-receipt.json
    jq -e '.repository.changedPaths | index(".claude/settings.json") != null' "$receipt" >/dev/null \
        || exit 27
    jq -e '.repository.changedPaths | index(".claude/skills/context-pack/SKILL.md") != null' \
        "$receipt" >/dev/null || exit 28

    staged=$(mktemp)
    jq '.metrics["comments:seedable-probe.sh"] = 1' substrate-baseline.json > "$staged" || exit 29
    mv "$staged" substrate-baseline.json
    read -r baseline_before _ < <(sha256sum substrate-baseline.json)
    if overlap_output=$(env -u CI "$KIT_ROOT/bin/substrate" init --profile shell --accept-baseline 2>&1); then
        exit 30
    fi
    case "$overlap_output" in
        *"maintenance overlaps dirty managed paths: substrate-baseline.json"*) ;;
        *) exit 31 ;;
    esac
    read -r baseline_after _ < <(sha256sum substrate-baseline.json)
    [ "$baseline_before" = "$baseline_after" ] || exit 32
    jq -e '.seedableProbe == "preserved"' .claude/settings.json >/dev/null || exit 33
    [ ! -e .claude/skills/context-pack/SKILL.md ] || exit 34
)
case $? in
    20) fail "seedable-overlap fixture setup failed" ;;
    21) fail "seedable-overlap fixture init failed" ;;
    22) fail "seedable-overlap fixture baseline failed" ;;
    23) fail "could not edit a seedable managed input" ;;
    24) fail "init rejected seedable dirty managed inputs" ;;
    25) fail "init dropped a seedable settings edit" ;;
    26) fail "init recreated a deleted repo-owned skill" ;;
    27|28) fail "maintenance receipt omitted seedable dirty inputs" ;;
    29) fail "could not edit the non-seedable managed input" ;;
    30) fail "init accepted a non-seedable dirty managed overlap" ;;
    31) fail "init did not identify the rejected managed overlap" ;;
    32) fail "failed overlap mutated the non-seedable managed input" ;;
    33) fail "failed overlap mutated the seedable settings input" ;;
    34) fail "failed overlap recreated the deleted seedable input" ;;
    0) ;;
    *) fail "seedable-overlap fixture failed unexpectedly" ;;
esac
rm -rf "$T3"

printf 'init-idempotent-test: hooks stable at %s groups, locked sync, seedable overlays, and overlap refusal green\n' "$count1"
