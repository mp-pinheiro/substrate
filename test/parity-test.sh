#!/usr/bin/env bash
# Structural mirror markers plus end-to-end lifecycle, checkpoint, command, and push parity.
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$KIT_ROOT" || exit 9

fail() { printf 'parity-test FAIL: %s\n' "$1" >&2; exit 1; }

checks.d/81-harness-parity.sh >/dev/null || fail "real tree does not pass structural parity"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
grep -v 'mirrors: gate-before-push.sh' core/omp/substrate-quality.ts > "$T/omp-stripped.ts"
out=$(checks.d/81-harness-parity.sh "$T/omp-stripped.ts")
rc=$?
[ "$rc" -ne 0 ] || fail "check stayed green with a stripped mirror"
printf '%s' "$out" | grep -q 'gate-before-push.sh' || fail "red run does not name the orphaned hook"

export HOME="$T/home"
export SUBSTRATE_NO_USER_HARNESS=1
mkdir -p "$HOME" "$T/repo"
cd "$T/repo" || exit 9
git init -q --initial-branch=main
git config user.name substrate
git config user.email substrate@localhost
printf '#!/usr/bin/env bash\nprintf "owned\\n"\n' > owned.sh
chmod +x owned.sh
"$KIT_ROOT/bin/substrate" init --profile shell --vcs git >/dev/null 2>&1 || fail "fixture init failed"
git add -A
git commit -qm 'chore: initialize'
.substrate/gate.sh --update-baseline >/dev/null 2>&1 || fail "fixture baseline failed"
git add substrate-baseline.json
git commit -qm 'chore: establish baseline'

git clone -q "$T/repo" "$T/dirty-repo"
git -C "$T/dirty-repo" config user.name substrate
git -C "$T/dirty-repo" config user.email substrate@localhost
printf 'printf "preexisting\\n"\n' >> "$T/dirty-repo/owned.sh"

cat > "$T/omp-lifecycle.ts" <<'TS'
import { appendFileSync, writeFileSync } from "node:fs";

const handlers: Record<string, any[]> = {};
const commands: Record<string, any> = {};
const tools: Record<string, any> = {};
const notifications: any[] = [];
const pi: any = {
	setLabel() {},
	on(name: string, handler: any) {
		(handlers[name] ??= []).push(handler);
	},
	registerCommand(name: string, command: any) {
		commands[name] = command;
	},
	registerTool(tool: any) {
		tools[tool.name] = tool;
	},
	typebox: {
		Type: {
			Object() {
				return {};
			},
			String() {
				return {};
			},
		},
	},
};
const extension = await import(process.argv[2]);
extension.default(pi);

function context(cwd: string) {
	return {
		cwd,
		ui: {
			notify(message: string, type: string) {
				notifications.push({ message, type });
			},
		},
	};
}
async function callAll(name: string, event: any, ctx: any) {
	const results = [];
	for (const handler of handlers[name] ?? []) {
		const result = await handler(event, ctx);
		if (result) results.push(result);
	}
	return results;
}
async function resultAll(event: any, ctx: any) {
	let current = event;
	let result = null;
	for (const handler of handlers.tool_result ?? []) {
		const next = await handler(current, ctx);
		if (next) {
			result = next;
			current = { ...current, ...next };
		}
	}
	return result;
}

const repo = process.argv[3];
const dirtyRepo = process.argv[4];
const ctx = context(repo);
await callAll("session_start", {}, ctx);
const writeEvent = {
	toolName: "write",
	toolCallId: "owned-write",
	input: { path: `${repo}/owned.sh` },
	content: [{ type: "text", text: "write complete" }],
	isError: false,
};
await callAll("tool_call", writeEvent, ctx);
appendFileSync(`${repo}/owned.sh`, 'printf "changed\\n"\n');
await resultAll(writeEvent, ctx);
const beforeStop = await handlers.session_stop[0]({ stop_hook_active: false }, ctx);
const checkpoint = await tools.substrate_checkpoint.execute(
	"checkpoint",
	{ message: "fix(shell): checkpoint omp work" },
	undefined,
	undefined,
	ctx,
);
const afterStop = (await handlers.session_stop[0]({ stop_hook_active: false }, ctx)) ?? null;
const commitBlocks = await callAll(
	"tool_call",
	{ toolName: "bash", toolCallId: "commit", input: { command: 'git commit -m "fix: bypass"' } },
	ctx,
);

const dirtyCtx = context(dirtyRepo);
await callAll("session_start", {}, dirtyCtx);
const dirtyCheckpoint = await tools.substrate_checkpoint.execute(
	"dirty-checkpoint",
	{ message: "fix(shell): reject dirty start" },
	undefined,
	undefined,
	dirtyCtx,
);

writeFileSync(`${repo}/orphan.xyz`, "plain text\n");
const addOrphan = Bun.spawnSync(["git", "add", "orphan.xyz"], { cwd: repo });
if (addOrphan.exitCode !== 0) throw new Error("failed to stage red push fixture");
const pushBlocks = await callAll(
	"tool_call",
	{ toolName: "bash", toolCallId: "push", input: { command: "git push origin main" } },
	ctx,
);
console.log(
	JSON.stringify({
		beforeStop,
		checkpoint,
		afterStop,
		commitBlocks,
		dirtyCheckpoint,
		pushBlocks,
		notifications,
	}),
);
TS

omp_results=$(bun "$T/omp-lifecycle.ts" "$KIT_ROOT/core/omp/substrate-quality.ts" "$T/repo" "$T/dirty-repo") \
    || fail "OMP lifecycle probe failed"
jq -e '.beforeStop.decision == "block" and (.beforeStop.reason | contains("Agent-owned pending paths: owned.sh"))' \
    <<< "$omp_results" >/dev/null || fail "OMP stop did not block pending owned work: $omp_results"
jq -e '.checkpoint.details.status == "passed" and (.checkpoint.isError // false) == false' \
    <<< "$omp_results" >/dev/null || fail "OMP checkpoint did not commit owned work: $omp_results"
jq -e '.afterStop == null' <<< "$omp_results" >/dev/null \
    || fail "OMP stop remained blocked after checkpoint: $omp_results"
jq -e 'any(.commitBlocks[]; .block == true and (.reason | contains("substrate_checkpoint")))' \
    <<< "$omp_results" >/dev/null || fail "OMP direct commit guard was not checkpoint-owned: $omp_results"
jq -e '.dirtyCheckpoint.isError == true and (.dirtyCheckpoint.content[0].text | contains("pre-existing work"))' \
    <<< "$omp_results" >/dev/null || fail "OMP checkpoint accepted a dirty task start: $omp_results"
jq -e 'any(.pushBlocks[]; .block == true and (.reason | contains("push guard rejected")))' \
    <<< "$omp_results" >/dev/null || fail "OMP red push was not blocked: $omp_results"
[ "$(git -C "$T/repo" log -1 --pretty=%s)" = 'fix(shell): checkpoint omp work' ] \
    || fail "OMP checkpoint wrote the wrong commit"
jq -e '.status == "passed" and .source == "checkpoint"' \
    "$T/repo/.git/substrate/gate-receipt.json" >/dev/null || fail "OMP checkpoint receipt missing"

commit_payload='{"tool_input":{"command":"git commit -m \"fix: bypass\""}}'
if printf '%s\n' "$commit_payload" | "$T/repo/.substrate/hooks/protect-command.sh" > "$T/claude-commit.out" 2>&1; then
    fail "Claude direct commit guard did not block"
fi
grep -Fq 'checkpoint transaction' "$T/claude-commit.out" \
    || fail "Claude direct commit rejection did not name the checkpoint"
push_payload='{"tool_input":{"command":"git push origin main"}}'
if printf '%s\n' "$push_payload" | "$T/repo/.substrate/hooks/gate-before-push.sh" > "$T/claude-push.out" 2>&1; then
    fail "Claude red push guard did not block"
fi
grep -Fq 'push blocked' "$T/claude-push.out" || fail "Claude red push rejection was not actionable"

printf 'parity-test: structural mirrors, lifecycle, checkpoint, command, push parity green\n'
