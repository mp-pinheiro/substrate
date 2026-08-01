#!/usr/bin/env bash
# User-level harness install: init must arm ~/.omp/agent/extensions and
# ~/.claude (idempotently, preserving foreign groups), the launcher must
# dispatch into a repo's vendored hooks from outside it (cross-repo payload
# routing — even when that repo carries its own inert project wiring), from
# a subdirectory (upward walk), stay silent where no substrate repo exists,
# stand down only for the session root, and ~/.omp/profiles is untouchable.
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'user-harness-test FAIL: %s\n' "$1" >&2; exit 1; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"
mkdir -p "$HOME/.claude" "$T/repo"

printf '{"hooks": {"PostToolUse": [{"matcher": "Write", "hooks": [{"type": "command", "command": "bash my-user-hook.sh"}]}]}}\n' \
    > "$HOME/.claude/settings.json"

cd "$T/repo" || exit 9
git init -q .
git config user.email substrate@localhost
git config user.name substrate
env -u CI -u SUBSTRATE_NO_USER_HARNESS "$KIT_ROOT/bin/substrate" init --profile shell >/dev/null 2>&1 \
    || fail "init failed"

[ -f "$HOME/.omp/agent/extensions/substrate-quality.ts" ] || fail "user-level omp extension not installed"
cmp -s "$HOME/.omp/agent/extensions/substrate-quality.ts" "$KIT_ROOT/core/omp/substrate-quality.ts" \
    || fail "user-level omp extension differs from kit copy"
[ -f "$HOME/.omp/agent/agents/explorer.md" ] || fail "user-level omp agent not installed"
[ -f "$HOME/.omp/agent/skills/review/SKILL.md" ] || fail "user-level omp skill not installed"
[ -f "$HOME/.claude/agents/explorer.md" ] || fail "user-level Claude agent not installed"
[ -f "$HOME/.claude/skills/review/SKILL.md" ] || fail "user-level Claude skill not installed"
cmp -s "$HOME/.omp/agent/agents/explorer.md" "$KIT_ROOT/agents/omp/explorer.md" \
    || fail "user-level omp agent differs from kit copy"
cmp -s "$HOME/.claude/skills/review/SKILL.md" "$KIT_ROOT/skills/review/SKILL.md" \
    || fail "user-level Claude skill differs from kit copy"
[ -e "$HOME/.omp/profiles" ] && fail "HOME/.omp/profiles was created — installer crossed into profile stacks"

count1=$(jq '[(.hooks.PreToolUse // [])[].hooks[].command, (.hooks.PostToolUse // [])[].hooks[].command] | map(select(test("substrate-launch"))) | length' "$HOME/.claude/settings.json")
[ "$count1" -ge 1 ] || fail "no substrate-launch registrations in user settings"
grep -q 'my-user-hook.sh' "$HOME/.claude/settings.json" || fail "pre-existing user hook group dropped"

env -u CI -u SUBSTRATE_NO_USER_HARNESS "$KIT_ROOT/bin/substrate" init --profile shell >/dev/null 2>&1
count2=$(jq '[(.hooks.PreToolUse // [])[].hooks[].command, (.hooks.PostToolUse // [])[].hooks[].command] | map(select(test("substrate-launch"))) | length' "$HOME/.claude/settings.json")
[ "$count1" = "$count2" ] || fail "substrate-launch registrations grew on re-run ($count1 -> $count2)"
grep -q 'my-user-hook.sh' "$HOME/.claude/settings.json" || fail "pre-existing user hook group dropped by re-run"

LAUNCH="$HOME/.claude/hooks/substrate-launch.sh"
[ -x "$LAUNCH" ] || fail "launcher not installed executable"

mkdir -p "$T/nowhere"
out=$(cd "$T/nowhere" && printf '{}' | CLAUDE_PROJECT_DIR="$T/nowhere" bash "$LAUNCH" protect-paths.sh 2>&1)
rc=$?
[ "$rc" -eq 0 ] || fail "launcher not a no-op outside substrate repos (rc=$rc)"
[ -z "$out" ] || fail "launcher noisy outside substrate repos: $out"

# cross-repo: the target repo's own project wiring is inert (Claude never loaded it) — must dispatch
grep -q 'protect-paths.sh' "$T/repo/.claude/settings.json" || fail "fixture drift: repo project wiring missing"
probe_abs=$(printf '{"tool_input": {"file_path": "%s"}}' "$T/repo/substrate-baseline.json")
out=$(cd "$T/nowhere" && printf '%s' "$probe_abs" | CLAUDE_PROJECT_DIR="$T/nowhere" bash "$LAUNCH" protect-paths.sh 2>&1)
rc=$?
[ "$rc" -eq 2 ] || fail "cross-repo dispatch failed despite inert project wiring (rc=$rc: $out)"
printf '%s' "$out" | grep -q 'baseline' || fail "cross-repo verdict lost: $out"

# subdirectory + relative payload path: upward walk from the target
mkdir -p "$T/repo/components"
out=$(cd "$T/repo/components" && printf '{"tool_input": {"file_path": "substrate-baseline.json"}}' \
    | env -u CLAUDE_PROJECT_DIR bash "$LAUNCH" protect-paths.sh 2>&1)
rc=$?
[ "$rc" -eq 2 ] || fail "subdirectory walk dispatch failed (rc=$rc: $out)"

# stand-down: the session root's own wiring is live — the launcher yields
out=$(cd "$T/repo" && printf '%s' "$probe_abs" | CLAUDE_PROJECT_DIR="$T/repo" bash "$LAUNCH" protect-paths.sh 2>&1)
rc=$?
[ "$rc" -eq 0 ] || fail "launcher double-fired despite live project wiring (rc=$rc)"

# per-hook scope: wiring for OTHER hooks must not suppress one the project does not register
tmp=$(mktemp)
jq '.hooks.PostToolUse = [{"matcher": "Write|Edit", "hooks": [{"type": "command", "command": "bash something-else.sh"}]}]' \
    "$T/repo/.claude/settings.json" > "$tmp" && mv "$tmp" "$T/repo/.claude/settings.json"
printf '#!/usr/bin/env bash\nls\n# now we check the thing\nls\n' > "$T/repo/components/gapfill.sh"
out=$(cd "$T/repo" && printf '{"tool_input": {"command": "true"}}' | CLAUDE_PROJECT_DIR="$T/repo" bash "$LAUNCH" changed-files-scan.sh 2>&1)
rc=$?
[ "$rc" -eq 2 ] || fail "gap-fill dispatch not observable (rc=$rc: $out)"
printf '%s' "$out" | grep -q 'components/gapfill.sh' || fail "gap-fill scan verdict lost: $out"
grep -qF '.substrate/hooks/changed-files-scan.sh' "$T/repo/.claude/settings.json" \
    && fail "fixture drift: scan hook unexpectedly project-wired"

printf 'user-harness-test: install, idempotency, no-op, cross-repo, walk, stand-down, gap-fill green\n'
