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
substrate-engine gate --update-baseline >/dev/null 2>&1 || fail "fixture baseline failed"
git add substrate-baseline.json
git commit -qm 'chore: establish baseline'

git clone -q "$T/repo" "$T/dirty-repo"
git -C "$T/dirty-repo" config user.name substrate
git -C "$T/dirty-repo" config user.email substrate@localhost
printf 'printf "preexisting\\n"\n' >> "$T/dirty-repo/owned.sh"

cat > "$T/omp-lifecycle.ts" <<'TS'
import { appendFileSync, writeFileSync } from "node:fs";

const { bootProbe } = await import(process.argv[3]);
const probe = await bootProbe(process.argv[2]);
const { callAll, resultAll, writeEvent, handlers, tools, notifications } = probe;

const repo = process.argv[4];
const dirtyRepo = process.argv[5];
const ctx = probe.context(repo);
await callAll("session_start", {}, ctx);
const deviceEvent = {
	toolName: "write",
	toolCallId: "device-write",
	input: { path: "xd://retain" },
	content: [{ type: "text", text: "memories stored" }],
	isError: false,
};
const deviceResult = (await resultAll(deviceEvent, ctx)) ?? null;
const slopEvent = writeEvent("slop-write", `${repo}/owned.sh`);
await callAll("tool_call", slopEvent, ctx);
appendFileSync(
	`${repo}/owned.sh`,
	"# now we check the thing\n# first we validate, then we proceed\n# finally we finish\n",
);
await resultAll(slopEvent, ctx);
const beforeStop = await handlers.session_stop[0]({ stop_hook_active: false }, ctx);
const ownedEvent = writeEvent("owned-write", `${repo}/owned.sh`);
await callAll("tool_call", ownedEvent, ctx);
writeFileSync(`${repo}/owned.sh`, '#!/usr/bin/env bash\nprintf "owned\\n"\nprintf "changed\\n"\n');
await resultAll(ownedEvent, ctx);
const progressFrames = [];
let loopTicks = 0;
const liveness = setInterval(() => {
	loopTicks++;
}, 20);
const checkpoint = await tools.substrate_checkpoint.execute(
	"checkpoint",
	{ message: "fix(shell): checkpoint omp work" },
	undefined,
	(partial) => progressFrames.push(partial.content[0]?.text ?? ""),
	ctx,
);
clearInterval(liveness);
const afterStop = (await handlers.session_stop[0]({ stop_hook_active: false }, ctx)) ?? null;
const extraEvent = writeEvent("extra-write", `${repo}/extra.sh`);
await callAll("tool_call", extraEvent, ctx);
writeFileSync(`${repo}/extra.sh`, '#!/usr/bin/env bash\nset -euo pipefail\nprintf "extra\\n"\n', {
	mode: 0o755,
});
await resultAll(extraEvent, ctx);
const autoStop = (await handlers.session_stop[0]({ stop_hook_active: false }, ctx)) ?? null;
const commitBlocks = await callAll(
	"tool_call",
	{ toolName: "bash", toolCallId: "commit", input: { command: 'git commit -m "fix: bypass"' } },
	ctx,
);

const dirtyCtx = probe.context(dirtyRepo);
await callAll("session_start", {}, dirtyCtx);
const dirtyCheckpoint = await tools.substrate_checkpoint.execute(
	"dirty-checkpoint",
	{ message: "fix(shell): reject dirty start" },
	undefined,
	undefined,
	dirtyCtx,
);

const dirtyWrite = writeEvent("dirty-write", `${dirtyRepo}/agent-new.sh`);
await callAll("tool_call", dirtyWrite, dirtyCtx);
writeFileSync(`${dirtyRepo}/agent-new.sh`, '#!/usr/bin/env bash\nset -euo pipefail\nprintf "agent\\n"\n', {
	mode: 0o755,
});
await resultAll(dirtyWrite, dirtyCtx);
const dirtySubset = await tools.substrate_checkpoint.execute(
	"dirty-subset",
	{ message: "feat(shell): checkpoint beside unowned work" },
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
		deviceResult,
		autoStop,
		dirtySubset,
		checkpoint,
		afterStop,
		commitBlocks,
		dirtyCheckpoint,
		pushBlocks,
		notifications,
		loopTicks,
		progressFrames: progressFrames.length,
	}),
);
TS

omp_results=$(bun "$T/omp-lifecycle.ts" "$KIT_ROOT/core/omp/substrate-quality.ts" \
    "$KIT_ROOT/test/lib/pi-probe.ts" "$T/repo" "$T/dirty-repo") \
    || fail "OMP lifecycle probe failed"
jq -e '.beforeStop.decision == "block" and (.beforeStop.reason | contains("Agent-owned pending paths: owned.sh")) and (.beforeStop.reason | contains("Automatic checkpoint failed"))' \
    <<< "$omp_results" >/dev/null || fail "OMP stop did not block red owned work with the auto-failure detail: $omp_results"
jq -e '.deviceResult == null and (.beforeStop.reason | contains("Ownership tracking error") | not)' \
    <<< "$omp_results" >/dev/null || fail "OMP tracked a non-filesystem device write as repo ownership: $omp_results"
jq -e '.checkpoint.details.status == "passed" and (.checkpoint.isError // false) == false' \
    <<< "$omp_results" >/dev/null || fail "OMP checkpoint did not commit owned work: $omp_results"
jq -e '.loopTicks > 10' <<< "$omp_results" >/dev/null \
    || fail "OMP checkpoint froze the event loop — the transaction must not block the render loop: $omp_results"
jq -e '.progressFrames > 0' <<< "$omp_results" >/dev/null \
    || fail "OMP checkpoint streamed no progress to onUpdate: $omp_results"
jq -e '.afterStop == null' <<< "$omp_results" >/dev/null \
    || fail "OMP stop remained blocked after checkpoint: $omp_results"
jq -e '.autoStop == null' <<< "$omp_results" >/dev/null \
    || fail "OMP stop did not auto-checkpoint green owned work: $omp_results"
jq -e 'any(.notifications[]; .message | contains("auto-checkpoint"))' \
    <<< "$omp_results" >/dev/null || fail "OMP auto-checkpoint was not surfaced: $omp_results"
jq -e 'any(.commitBlocks[]; .block == true and (.reason | contains("substrate_checkpoint")))' \
    <<< "$omp_results" >/dev/null || fail "OMP direct commit guard was not checkpoint-owned: $omp_results"
jq -e '.dirtyCheckpoint.isError == true and (.dirtyCheckpoint.content[0].text | contains("no pending agent-owned changes"))' \
    <<< "$omp_results" >/dev/null || fail "OMP checkpoint without owned work did not refuse: $omp_results"
jq -e '.dirtySubset.details.status == "passed" and (.dirtySubset.content[0].text | contains("Unowned pending paths left in place: owned.sh"))' \
    <<< "$omp_results" >/dev/null || fail "OMP path-scoped checkpoint did not commit beside unowned work: $omp_results"
[ "$(git -C "$T/dirty-repo" log -1 --pretty=%s)" = 'feat(shell): checkpoint beside unowned work' ] \
    || fail "OMP path-scoped checkpoint wrote the wrong commit"
[ -n "$(git -C "$T/dirty-repo" status --porcelain=v1 -- owned.sh)" ] \
    || fail "OMP path-scoped checkpoint consumed the unowned pre-existing edit"
git -C "$T/dirty-repo" show --name-only --pretty=format: HEAD | grep -qx 'owned.sh' \
    && fail "unowned owned.sh leaked into the OMP path-scoped commit"
jq -e 'any(.pushBlocks[]; .block == true and (.reason | contains("push guard rejected")))' \
    <<< "$omp_results" >/dev/null || fail "OMP red push was not blocked: $omp_results"
[ "$(git -C "$T/repo" log -1 --pretty=%s)" = 'chore(agent): checkpoint owned work at session stop' ] \
    || fail "OMP auto-checkpoint wrote the wrong commit"
[ "$(git -C "$T/repo" log -2 --pretty=%s | tail -n 1)" = 'fix(shell): checkpoint omp work' ] \
    || fail "OMP checkpoint wrote the wrong commit"
jq -e '.status == "passed" and .source == "checkpoint"' \
    "$T/repo/.git/substrate/gate-receipt.json" >/dev/null || fail "OMP checkpoint receipt missing"

cat > "$T/omp-hydrate.ts" <<'TS'
import { appendFileSync } from "node:fs";

const { bootProbe } = await import(process.argv[3]);
const probe = await bootProbe(process.argv[2]);
const repo = process.argv[4];
const mode = process.argv[5];
const ctx = probe.context(repo);
await probe.callAll("session_start", {}, ctx);
if (mode === "seed") {
	const seedEvent = probe.writeEvent("hydrate-write", `${repo}/owned.sh`);
	await probe.callAll("tool_call", seedEvent, ctx);
	appendFileSync(`${repo}/owned.sh`, 'printf "hydrated\\n"\n');
	await probe.resultAll(seedEvent, ctx);
	console.log(JSON.stringify({ seeded: true }));
} else {
	const checkpoint = await probe.tools.substrate_checkpoint.execute(
		"hydrated-checkpoint",
		{ message: "fix(shell): checkpoint hydrated work" },
		undefined,
		undefined,
		ctx,
	);
	console.log(JSON.stringify({ checkpoint }));
}
TS

git clone -q "$T/repo" "$T/hydrate-repo"
git -C "$T/hydrate-repo" config user.name substrate
git -C "$T/hydrate-repo" config user.email substrate@localhost
bun "$T/omp-hydrate.ts" "$KIT_ROOT/core/omp/substrate-quality.ts" "$KIT_ROOT/test/lib/pi-probe.ts" \
    "$T/hydrate-repo" seed >/dev/null \
    || fail "hydration seed probe failed"
digest=$(printf '%s' "$T/hydrate-repo" | sha256sum | cut -c1-16)
jq -e '.task.ownedEntries["owned.sh"] | type == "string"' \
    "$HOME/.omp/run/substrate-quality/$digest.json" >/dev/null \
    || fail "per-root runtime ledger did not persist owned entries"
hydrated=$(bun "$T/omp-hydrate.ts" "$KIT_ROOT/core/omp/substrate-quality.ts" "$KIT_ROOT/test/lib/pi-probe.ts" \
    "$T/hydrate-repo" hydrate) \
    || fail "hydration checkpoint probe failed"
jq -e '.checkpoint.details.status == "passed"' <<< "$hydrated" >/dev/null \
    || fail "restarted process did not hydrate prior ownership: $hydrated"
[ "$(git -C "$T/hydrate-repo" log -1 --pretty=%s)" = 'fix(shell): checkpoint hydrated work' ] \
    || fail "hydrated checkpoint wrote the wrong commit"
[ -z "$(git -C "$T/hydrate-repo" status --porcelain=v1 --untracked-files=all)" ] \
    || fail "hydrated checkpoint left pending work"

commit_payload='{"tool_input":{"command":"git commit -m \"fix: bypass\""}}'
if printf '%s\n' "$commit_payload" | "$T/repo/substrate-engine hook protect-command" > "$T/claude-commit.out" 2>&1; then
    fail "Claude direct commit guard did not block"
fi
grep -Fq 'checkpoint transaction' "$T/claude-commit.out" \
    || fail "Claude direct commit rejection did not name the checkpoint"
push_payload='{"tool_input":{"command":"git push origin main"}}'
if printf '%s\n' "$push_payload" | "$T/repo/substrate-engine hook gate-before-push" > "$T/claude-push.out" 2>&1; then
    fail "Claude red push guard did not block"
fi
grep -Fq 'push blocked' "$T/claude-push.out" || fail "Claude red push rejection was not actionable"

printf 'parity-test: structural mirrors, lifecycle, checkpoint, command, push parity green\n'
