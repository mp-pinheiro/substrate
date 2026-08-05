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

printf '{"hooks": {"PostToolUse": [{"matcher": "Write", "hooks": [{"type": "command", "command": "bash my-user-hook.sh"}, {"type": "command", "command": "bash \\\"$HOME/.claude/hooks/substrate-launch.sh\\\" retired-hook.sh"}]}]}}\n' \
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
[ -f "$HOME/.omp/agent/extensions/substrate-quality/runtime.ts" ] \
    || fail "user-level omp runtime module not installed"
[ -f "$HOME/.omp/agent/extensions/substrate-quality/lifecycle.ts" ] \
    || fail "user-level omp lifecycle module not installed"
[ -f "$HOME/.omp/agent/extensions/substrate-quality/identity.ts" ] \
    || fail "user-level omp identity module not installed"
cmp -s "$HOME/.omp/agent/extensions/substrate-quality/runtime.ts" \
    "$KIT_ROOT/core/omp/substrate-quality/runtime.ts" \
    || fail "user-level omp runtime module differs from kit copy"
cmp -s "$HOME/.omp/agent/extensions/substrate-quality/lifecycle.ts" \
    "$KIT_ROOT/core/omp/substrate-quality/lifecycle.ts" \
    || fail "user-level omp lifecycle module differs from kit copy"
cmp -s "$HOME/.omp/agent/extensions/substrate-quality/identity.ts" \
    "$KIT_ROOT/core/omp/substrate-quality/identity.ts" \
    || fail "user-level omp identity module differs from kit copy"
[ -f "$HOME/.omp/agent/agents/explorer.md" ] || fail "user-level omp agent not installed"
[ -f "$HOME/.omp/agent/skills/review/SKILL.md" ] || fail "user-level omp skill not installed"
[ -f "$HOME/.claude/agents/explorer.md" ] || fail "user-level Claude agent not installed"
[ -f "$HOME/.claude/skills/review/SKILL.md" ] || fail "user-level Claude skill not installed"
cmp -s "$HOME/.omp/agent/agents/explorer.md" "$KIT_ROOT/agents/omp/explorer.md" \
    || fail "user-level omp agent differs from kit copy"
cmp -s "$HOME/.claude/skills/review/SKILL.md" "$KIT_ROOT/skills/review/SKILL.md" \
    || fail "user-level Claude skill differs from kit copy"
[ -e "$HOME/.omp/profiles" ] && fail "HOME/.omp/profiles was created — installer crossed into profile stacks"

# The user-level omp extension resolves each write target, not the session cwd.
mkdir -p "$T/nowhere" "$T/repo/components"
printf '#!/usr/bin/env bash\nls\n' > "$T/repo/components/gapfill.sh"
cat > "$T/omp-probe.ts" <<'TS'
import { appendFileSync } from "node:fs";
const { bootProbe } = await import(process.argv[3]);
const probe = await bootProbe(process.argv[2]);
const handlers = probe.handlers;
const protect = handlers.tool_call[0];
const policy = handlers.before_agent_start[0];
const outsideCwd = process.argv[4];
const repoCwd = process.argv[5];
const scanFile = process.argv[6];
const context = probe.context(repoCwd);
await handlers.session_start[0]({}, context);
await probe.commands.substrate.handler("", context);
const writes = [];
for (const path of process.argv.slice(7)) {
	writes.push(await protect({ toolName: "write", input: { path } }, { cwd: outsideCwd }));
}
const policyRepo = await policy({ systemPrompt: ["base"] }, { cwd: repoCwd });
const policyOutside = await policy({ systemPrompt: ["base"] }, { cwd: outsideCwd });
const lspCall = {
	toolName: "lsp",
	toolCallId: "mutating-lsp",
	input: { action: "rename", file: scanFile },
	content: [{ type: "text", text: "rename applied" }],
	isError: false,
};
await probe.callAll("tool_call", lspCall, { cwd: outsideCwd });
appendFileSync(scanFile, "# now we check the thing\n");
const lsp = await probe.resultAll(lspCall, { cwd: outsideCwd });
const lspRead = await probe.resultAll(
	{
		toolName: "lsp",
		toolCallId: "read-lsp",
		input: { action: "references", file: scanFile },
		content: [{ type: "text", text: "references found" }],
		isError: false,
	},
	{ cwd: outsideCwd },
);
console.log(
	JSON.stringify({
		writes,
		policy: { repo: policyRepo, outside: policyOutside ?? null },
		lsp,
		lspRead: lspRead ?? null,
		identity: { label: probe.label(), notifications: probe.notifications },
	}),
);
TS
ln -s "$T/nowhere" "$T/repo/escaped-parent"
omp_results=$(bun "$T/omp-probe.ts" "$HOME/.omp/agent/extensions/substrate-quality.ts" \
	"$KIT_ROOT/test/lib/pi-probe.ts" \
	"$T/nowhere" "$T/repo" "$T/repo/components/gapfill.sh" \
	"$T/repo/missing/deep/substrate-baseline.json" \
	"$T/repo/escaped-parent/missing/file.sh")
jq -e '.writes[0].block == true and (.writes[0].reason | contains("baseline"))' <<< "$omp_results" >/dev/null \
	|| fail "user-level omp extension missed a cross-repo protected write: $omp_results"
jq -e '.writes[1].block == true and (.writes[1].reason | contains("outside the repo"))' <<< "$omp_results" >/dev/null \
	|| fail "user-level omp extension missed a missing-parent symlink escape: $omp_results"
jq -e '.policy.repo.systemPrompt[-1] | contains("governed by Substrate")' <<< "$omp_results" >/dev/null \
	|| fail "user-level omp extension did not inject repository policy: $omp_results"
jq -e '.policy.outside == null' <<< "$omp_results" >/dev/null \
	|| fail "user-level omp extension injected policy outside a substrate repo: $omp_results"
jq -e '.lsp.content[-1].text | contains("components/gapfill.sh")' <<< "$omp_results" >/dev/null \
	|| fail "user-level omp extension skipped a mutating cross-repo lsp result: $omp_results"
jq -e '.lspRead == null' <<< "$omp_results" >/dev/null \
	|| fail "user-level omp extension scanned a read-only lsp result: $omp_results"
read -r extension_hash _ < <(
	cat "$HOME/.omp/agent/extensions/substrate-quality.ts" \
		"$HOME/.omp/agent/extensions/substrate-quality/runtime.ts" \
		"$HOME/.omp/agent/extensions/substrate-quality/lifecycle.ts" \
		"$HOME/.omp/agent/extensions/substrate-quality/identity.ts" \
		"$HOME/.omp/agent/extensions/substrate-quality/policy.ts" \
		"$HOME/.omp/agent/extensions/substrate-quality/transactions.ts" \
		"$HOME/.omp/agent/extensions/substrate-quality/restructure.ts" |
		sha256sum
)
extension_path=$(realpath "$HOME/.omp/agent/extensions/substrate-quality.ts")
jq -e --arg path "$extension_path" --arg hash "$extension_hash" \
	'.extensionPath == $path and .extensionHash == $hash' \
	"$HOME/.omp/run/substrate-quality.json" >/dev/null \
	|| fail "runtime identity does not name the installed extension"
jq -e --arg short "${extension_hash:0:8}" --arg path "$extension_path" --arg hash "$extension_hash" \
	'.identity.label == ("Substrate " + $short)
	 and any(.identity.notifications[]; (.message | contains($path)) and (.message | contains($hash)))' \
	<<< "$omp_results" >/dev/null \
	|| fail "runtime summary did not expose the installed extension identity: $omp_results"

count1=$(jq '[(.hooks.PreToolUse // [])[].hooks[].command, (.hooks.PostToolUse // [])[].hooks[].command] | map(select(test("substrate-launch"))) | length' "$HOME/.claude/settings.json")
[ "$count1" -ge 1 ] || fail "no substrate-launch registrations in user settings"
grep -q 'my-user-hook.sh' "$HOME/.claude/settings.json" || fail "pre-existing user hook group dropped"
grep -q 'retired-hook.sh' "$HOME/.claude/settings.json" \
    && fail "retired managed hook survived mixed user-hook group synchronization"

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

# Target routing starts at lexical parents, even before they exist.
probe_missing=$(printf '{"tool_input": {"file_path": "%s"}}' "$T/repo/missing/deep/substrate-baseline.json")
out=$(cd "$T/nowhere" && printf '%s' "$probe_missing" \
    | CLAUDE_PROJECT_DIR="$T/nowhere" bash "$LAUNCH" protect-paths.sh 2>&1)
rc=$?
[ "$rc" -eq 2 ] || fail "missing-parent target bypassed launcher routing (rc=$rc: $out)"
printf '%s' "$out" | grep -q 'baseline' || fail "missing-parent target verdict lost: $out"

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
jq '.note = ".substrate/hooks/changed-files-scan.sh"
    | .hooks.PostToolUse = [{"matcher": "Write|Edit", "hooks": [{"type": "command", "command": "bash something-else.sh"}]}]' \
    "$T/repo/.claude/settings.json" > "$tmp" && mv "$tmp" "$T/repo/.claude/settings.json"
printf '#!/usr/bin/env bash\nls\n# now we check the thing\nls\n' > "$T/repo/components/gapfill.sh"
out=$(cd "$T/repo" && printf '{"tool_input": {"command": "true"}}' | CLAUDE_PROJECT_DIR="$T/repo" bash "$LAUNCH" changed-files-scan.sh 2>&1)
rc=$?
[ "$rc" -eq 2 ] || fail "gap-fill dispatch not observable (rc=$rc: $out)"
printf '%s' "$out" | grep -q 'components/gapfill.sh' || fail "gap-fill scan verdict lost: $out"
jq -e --arg command 'bash "${CLAUDE_PROJECT_DIR:-.}/.substrate/hooks/changed-files-scan.sh"' '
    [(.hooks.PreToolUse // [])[], (.hooks.PostToolUse // [])[]]
    | any(.[] | .hooks[]?; .command == $command)
' "$T/repo/.claude/settings.json" >/dev/null \
    && fail "fixture drift: scan hook unexpectedly project-wired"


# User settings symlinks and symlinked ancestors are never replaced or traversed.
HOME2="$T/home-symlink"
mkdir -p "$HOME2/.claude" "$T/symlink-user-repo"
printf '{"hooks":{"PreToolUse":[]}}\n' > "$T/external-settings.json"
settings_before=$(sha256sum "$T/external-settings.json")
ln -s "$T/external-settings.json" "$HOME2/.claude/settings.json"
cd "$T/symlink-user-repo" || exit 9
git init -q .
git config user.email substrate@localhost
git config user.name substrate
if HOME="$HOME2" env -u CI -u SUBSTRATE_NO_USER_HARNESS \
    "$KIT_ROOT/bin/substrate" init --profile shell > bootstrap.out 2>&1; then
    fail "init replaced a symlinked user settings file"
fi
[ -L "$HOME2/.claude/settings.json" ] || fail "user settings symlink was replaced"
[ "$settings_before" = "$(sha256sum "$T/external-settings.json")" ] \
    || fail "user settings symlink target changed"
printf 'user-harness-test: install, policy, lsp scan, idempotency, no-op, cross-repo, walk, stand-down, gap-fill green\n'
