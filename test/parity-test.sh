#!/usr/bin/env bash
# Structural mirror markers plus end-to-end lifecycle, checkpoint, command, and push parity.
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$KIT_ROOT" || exit 9

fail() { printf 'parity-test FAIL: %s\n' "$1" >&2; exit 1; }

checks.d/81-engine-ts-parity.sh >/dev/null || fail "real tree does not pass engine-ts parity"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

export HOME="$T/home"
export SUBSTRATE_NO_USER_HARNESS=1
mkdir -p "$HOME" "$T/repo"
cd "$T/repo" || exit 9
git init -q --initial-branch=main
git config user.name substrate
git config user.email substrate@localhost
printf '#!/usr/bin/env bash\nprintf "owned\\n"\n' > owned.sh
chmod +x owned.sh
"$KIT_ROOT/bin/substrate" init --profile shell --vcs git --from-worktree >/dev/null 2>&1 || fail "fixture init failed"
git add -A
git commit -qm 'chore: initialize'
substrate-engine gate --update-baseline >/dev/null 2>&1 || fail "fixture baseline failed"
git add substrate-baseline.json
git commit -qm 'chore: establish baseline'

git clone -q "$T/repo" "$T/dirty-repo"
git -C "$T/dirty-repo" config user.name substrate
git -C "$T/dirty-repo" config user.email substrate@localhost
printf 'printf "preexisting\\n"\n' >> "$T/dirty-repo/owned.sh"
git init -q --initial-branch=main "$T/plain-jj"
(cd "$T/plain-jj" && jj git init --colocate) >/dev/null 2>&1 || fail "plain jj fixture failed"
git clone -q "$T/repo" "$T/jj-sub"
git -C "$T/jj-sub" config user.name substrate
git -C "$T/jj-sub" config user.email substrate@localhost
(cd "$T/jj-sub" && jj git init --colocate) >/dev/null 2>&1 || fail "substrate jj fixture failed"
git clone -q "$T/repo" "$T/accept-repo"
git -C "$T/accept-repo" config user.name substrate
git -C "$T/accept-repo" config user.email substrate@localhost

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
const plainJjCtx = probe.context(process.argv[6]);
const plainPushBlocks = await callAll(
	"tool_call",
	{ toolName: "bash", toolCallId: "plain-push", input: { command: "git push origin main" } },
	plainJjCtx,
);
const plainCommitBlocks = await callAll(
	"tool_call",
	{ toolName: "bash", toolCallId: "plain-commit", input: { command: "git commit -m x" } },
	plainJjCtx,
);
const jjSubCtx = probe.context(process.argv[7]);
const jjPushBlocks = await callAll(
	"tool_call",
	{ toolName: "bash", toolCallId: "jj-push", input: { command: "jj git push" } },
	jjSubCtx,
);
const vcsBlocks = (command: string) =>
	callAll("tool_call", { toolName: "bash", toolCallId: command, input: { command } }, jjSubCtx);
const plainTarget = process.argv[6];
const crossRepo = {
	plainAdd: await vcsBlocks(`git -C ${plainTarget} add .`),
	plainCommit: await vcsBlocks(`git -C ${plainTarget} commit -m "fix: elsewhere"`),
	homeCommit: await vcsBlocks('git -C ~/elsewhere commit -m "fix: elsewhere"'),
	selfAdd: await vcsBlocks(`git -C ${process.argv[7]} add .`),
	governedCommit: await vcsBlocks(`git -C ${process.argv[4]} commit -m "fix: governed"`),
	mixedAdd: await vcsBlocks(`git -C ${plainTarget} add . && git add .`),
	mixedPathGuard: await vcsBlocks(`git -C ${plainTarget} status && rm -rf .substrate`),
};
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
		plainPushBlocks,
		plainCommitBlocks,
		jjPushBlocks,
		crossRepo,
		notifications,
		loopTicks,
		progressFrames: progressFrames.length,
	}),
);
TS

omp_results=$(bun "$T/omp-lifecycle.ts" "$KIT_ROOT/core/omp/substrate-quality.ts" \
    "$KIT_ROOT/test/lib/pi-probe.ts" "$T/repo" "$T/dirty-repo" "$T/plain-jj" "$T/jj-sub") \
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
jq -e '(.plainPushBlocks | length) == 0 and (.plainCommitBlocks | length) == 0' \
    <<< "$omp_results" >/dev/null || fail "OMP enforced jj governance in a non-substrate jj repo: $omp_results"
jq -e '(.jjPushBlocks | map(select((.reason // "") | contains("jj-managed"))) | length) == 0' \
    <<< "$omp_results" >/dev/null || fail "OMP blocked the sanctioned jj git push in a substrate repo: $omp_results"
jq -e '[.crossRepo.plainAdd, .crossRepo.plainCommit, .crossRepo.homeCommit] | all(length == 0)' \
    <<< "$omp_results" >/dev/null || fail "OMP blocked git aimed at a repository outside Substrate: $omp_results"
jq -e '.crossRepo.selfAdd | any(.block == true and (.reason | contains("jj-managed")))' \
    <<< "$omp_results" >/dev/null || fail "OMP let git -C mutate its own jj-governed repository: $omp_results"
jq -e '.crossRepo.governedCommit | any(.block == true)' \
    <<< "$omp_results" >/dev/null || fail "OMP let git -C commit into another governed repository: $omp_results"
jq -e '.crossRepo.mixedAdd | any(.block == true and (.reason | contains("jj-managed")))' \
    <<< "$omp_results" >/dev/null || fail "OMP skipped jj governance for the unnamed half of a mixed command: $omp_results"
jq -e '.crossRepo.mixedPathGuard | any(.block == true)' \
    <<< "$omp_results" >/dev/null || fail "OMP skipped the path guard when one segment named another repository: $omp_results"
[ "$(git -C "$T/repo" log -1 --pretty=%s)" = 'chore(agent): checkpoint owned work at session stop' ] \
    || fail "OMP auto-checkpoint wrote the wrong commit"
[ "$(git -C "$T/repo" log -2 --pretty=%s | tail -n 1)" = 'fix(shell): checkpoint omp work' ] \
    || fail "OMP checkpoint wrote the wrong commit"
jq -e '.status == "passed" and .source == "checkpoint"' \
    "$T/repo/.git/substrate/gate-receipt.json" >/dev/null || fail "OMP checkpoint receipt missing"

cat > "$T/omp-acceptance.ts" <<'TS'
import { execFileSync } from "node:child_process";
import { writeFileSync } from "node:fs";

const { bootProbe } = await import(process.argv[3]);
const probe = await bootProbe(process.argv[2]);
const { callAll, resultAll, writeEvent, tools, prompts } = probe;
const repo = process.argv[4];
const params = {
	message: "fix(shell): accept a reviewed regression",
	acceptRegression: ["dup_pct"],
	acceptRegressionReason: "denominator shrank after deleting duplicated lines",
};

const silent = probe.context(repo);
await callAll("session_start", {}, silent);
const ownedEvent = writeEvent("owned-write", `${repo}/owned.sh`);
await callAll("tool_call", ownedEvent, silent);
writeFileSync(`${repo}/owned.sh`, '#!/usr/bin/env bash\nprintf "owned\\n"\nprintf "accepted\\n"\n');
await resultAll(ownedEvent, silent);

const noUI = await tools.substrate_checkpoint.execute("no-ui", params, undefined, undefined, silent);
const promptsAfterNoUI = prompts.length;
const declining = probe.context(repo, { hasUI: true, approve: false });
const declined = await tools.substrate_checkpoint.execute("declined", params, undefined, undefined, declining);
const promptsAfterDecline = prompts.length;
const approving = probe.context(repo, { hasUI: true, approve: true });
const approved = await tools.substrate_checkpoint.execute("approved", params, undefined, undefined, approving);
const approvedHead = execFileSync("git", ["-C", repo, "log", "-1", "--pretty=%s"], { encoding: "utf8" }).trim();
const updateNoUI = await tools.substrate_update.execute(
	"update-no-ui",
	{ acceptRegression: ["dup_pct"], acceptRegressionReason: params.acceptRegressionReason },
	undefined,
	undefined,
	silent,
);
const update = await tools.substrate_update.execute("update", {}, undefined, undefined, silent);

console.log(
	JSON.stringify({
		noUI,
		promptsAfterNoUI,
		declined,
		promptsAfterDecline,
		prompts,
		approved,
		approvedHead,
		updateNoUI,
		update,
	}),
);
TS

acceptance=$(PATH="$KIT_ROOT/bin:$PATH" bun "$T/omp-acceptance.ts" "$KIT_ROOT/core/omp/substrate-quality.ts" \
    "$KIT_ROOT/test/lib/pi-probe.ts" "$T/accept-repo") \
    || fail "OMP acceptance probe failed"
jq -e '.noUI.isError == true and (.noUI.content[0].text | contains("needs the user'"'"'s approval")) and .promptsAfterNoUI == 0' \
    <<< "$acceptance" >/dev/null || fail "OMP checkpoint accepted a regression without a UI to ask: $acceptance"
jq -e '.declined.isError == true and (.declined.content[0].text | contains("declined")) and .promptsAfterDecline == 1' \
    <<< "$acceptance" >/dev/null || fail "OMP checkpoint did not stop on a declined regression: $acceptance"
jq -e '.prompts[0].title == "Substrate: accept ratchet regression?" and (.prompts[0].message | contains("dup_pct")) and (.prompts[0].message | contains("denominator shrank"))' \
    <<< "$acceptance" >/dev/null || fail "OMP regression prompt did not name the metric and reason: $acceptance"
jq -e '.approved.details.status == "passed" and (.approved.isError // false) == false and (.prompts | length) == 2' \
    <<< "$acceptance" >/dev/null || fail "OMP checkpoint did not commit after the user approved the regression: $acceptance"
jq -e '.approvedHead == "fix(shell): accept a reviewed regression"' \
    <<< "$acceptance" >/dev/null || fail "OMP approved checkpoint wrote the wrong commit: $acceptance"
jq -e '.updateNoUI.isError == true and (.updateNoUI.content[0].text | contains("needs the user'"'"'s approval")) and (.prompts | length) == 2' \
    <<< "$acceptance" >/dev/null || fail "OMP update accepted a regression without a UI to ask: $acceptance"
jq -e '(.update.isError // false) == false and .update.details.operation == "update" and (.update.details.status == "committed" or .update.details.status == "noop")' \
    <<< "$acceptance" >/dev/null || fail "OMP update did not run the maintenance transaction: $acceptance"

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
jq -e '.observed.entries["owned.sh"] | type == "string"' \
    "$T/hydrate-repo/.git/substrate/agent-sessions/substrate-omp-$digest.json" >/dev/null \
    || fail "engine session ledger did not persist owned entries"
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
if printf '%s\n' "$commit_payload" | ( cd "$T/repo" && substrate-engine hook protect-command ) > "$T/claude-commit.out" 2>&1; then
    fail "Claude direct commit guard did not block"
fi
grep -Fq 'checkpoint transaction' "$T/claude-commit.out" \
    || fail "Claude direct commit rejection did not name the checkpoint"
push_payload='{"tool_input":{"command":"git push origin main"}}'
if printf '%s\n' "$push_payload" | ( cd "$T/repo" && substrate-engine hook gate-before-push ) > "$T/claude-push.out" 2>&1; then
    fail "Claude red push guard did not block"
fi
grep -Fq 'push blocked' "$T/claude-push.out" || fail "Claude red push rejection was not actionable"

cat > "$T/omp-registration.ts" <<'TS'
const { bootProbe } = await import(process.argv[3]);
const probe = await bootProbe(process.argv[2]);
console.log(JSON.stringify({ tools: Object.keys(probe.tools).sort() }));
TS

# gate tools are advertised for the whole session, so a session rooted outside
# a substrate repo must not see them at all
outside_tools=$(cd "$T/plain-jj" && bun "$T/omp-registration.ts" \
    "$KIT_ROOT/core/omp/substrate-quality.ts" "$KIT_ROOT/test/lib/pi-probe.ts") \
    || fail "OMP registration probe failed outside a substrate repo"
jq -e '.tools == []' <<< "$outside_tools" >/dev/null \
    || fail "OMP advertised gate tools outside a substrate repo: $outside_tools"
inside_tools=$(cd "$T/repo" && bun "$T/omp-registration.ts" \
    "$KIT_ROOT/core/omp/substrate-quality.ts" "$KIT_ROOT/test/lib/pi-probe.ts") \
    || fail "OMP registration probe failed inside a substrate repo"
jq -e '.tools == ["substrate_checkpoint", "substrate_restructure", "substrate_update"]' <<< "$inside_tools" >/dev/null \
    || fail "OMP did not advertise gate tools inside a substrate repo: $inside_tools"

stub_engine() {
    cat > "$T/$1-engine" <<SH
#!/usr/bin/env bash
if [ "\${1:-} \${2:-}" = "hook protect-paths" ]; then
    cat >/dev/null
    printf '%s\n' '$2'
    exit 0
fi
exec '$(command -v substrate-engine)' "\$@"
SH
    chmod +x "$T/$1-engine"
}
stub_engine warn '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"stub warning"},"systemMessage":"stub warning"}'
stub_engine garbage 'not a decision'
git clone -q "$T/repo" "$T/ask-repo"
git -C "$T/ask-repo" config user.name substrate
git -C "$T/ask-repo" config user.email substrate@localhost
cat > "$T/omp-ask.ts" <<'TS'
import { appendFileSync } from "node:fs";

const [extensionPath, probePath, repo, warnEngine, garbageEngine] = process.argv.slice(2);
const { bootProbe } = await import(probePath);
const probe = await bootProbe(extensionPath);
const approve = probe.context(repo, { hasUI: true, approve: true });
const decline = probe.context(repo, { hasUI: true, approve: false });
await probe.callAll("session_start", {}, approve);
const guide = probe.writeEvent("guide-write", `${repo}/CLAUDE.md`);
const approved = await probe.callAll("tool_call", guide, approve);
appendFileSync(`${repo}/CLAUDE.md`, "Approved by the user\n");
await probe.resultAll(guide, approve);
const declined = await probe.callAll("tool_call", probe.writeEvent("agents-write", `${repo}/AGENTS.md`), decline);
const noUi = await probe.callAll("tool_call", probe.writeEvent("headless-write", `${repo}/CLAUDE.md`), probe.context(repo));
const bashCall = { toolName: "bash", toolCallId: "bash-ask", input: { command: "perl -pi -e 's/a/b/' AGENTS.md" } };
const bashDeclined = await probe.callAll("tool_call", bashCall, decline);
const owned = probe.writeEvent("owned-ask-write", `${repo}/owned.sh`);
await probe.callAll("tool_call", owned, approve);
appendFileSync(`${repo}/owned.sh`, 'printf "omp\\n"\n');
await probe.resultAll(owned, approve);
const stop = (await probe.handlers.session_stop[0]({ stop_hook_active: false }, approve)) ?? null;
process.env.SUBSTRATE_ENGINE_BIN = warnEngine;
const warned = await probe.callAll("tool_call", probe.writeEvent("warn-write", `${repo}/notes.txt`), approve);
process.env.SUBSTRATE_ENGINE_BIN = garbageEngine;
const unreadable = await probe.callAll("tool_call", probe.writeEvent("garbage-write", `${repo}/notes.txt`), approve);
const { prompts, notifications } = probe;
console.log(JSON.stringify({ approved, declined, noUi, bashDeclined, stop, warned, unreadable, prompts, notifications }));
TS
ask=$(bun "$T/omp-ask.ts" "$KIT_ROOT/core/omp/substrate-quality.ts" "$KIT_ROOT/test/lib/pi-probe.ts" \
    "$T/ask-repo" "$T/warn-engine" "$T/garbage-engine") || fail "OMP ask probe failed"
jq -e '(.approved | length) == 0 and (.prompts | length) == 3' <<< "$ask" >/dev/null \
    || fail "OMP did not ask exactly once per interactive ask-level call: $ask"
jq -e 'any(.prompts[]; .message | contains("CLAUDE.md holds agent instructions"))' <<< "$ask" >/dev/null \
    || fail "OMP prompt did not explain the ask: $ask"
jq -e 'any(.declined[]; .block == true and (.reason | contains("declined")) and (.reason | contains("AGENTS.md")))' <<< "$ask" >/dev/null \
    || fail "OMP did not block a declined edit: $ask"
jq -e 'any(.noUi[]; .block == true and (.reason | contains("no UI")))' <<< "$ask" >/dev/null \
    || fail "OMP did not fail closed without a UI: $ask"
jq -e 'any(.bashDeclined[]; .block == true and (.reason | contains("declined")))' <<< "$ask" >/dev/null \
    || fail "OMP did not block a declined bash command: $ask"
jq -e '.stop == null and any(.notifications[]; .message | contains("Left for the user to review and commit: CLAUDE.md"))' <<< "$ask" >/dev/null \
    || fail "OMP stop did not hand off the approved guide edit: $ask"
jq -e 'any(.warned[]; .additionalContext == "Substrate warning: stub warning") and any(.notifications[]; .type == "warning" and .message == "stub warning")' <<< "$ask" >/dev/null \
    || fail "OMP did not surface a warn decision: $ask"
jq -e 'any(.unreadable[]; .block == true and (.reason | contains("unreadable policy decision")))' <<< "$ask" >/dev/null \
    || fail "OMP accepted an unreadable decision: $ask"
git -C "$T/ask-repo" show --name-only --pretty=format: HEAD | grep -qx CLAUDE.md && fail "CLAUDE.md leaked into the OMP auto-checkpoint"
[ -n "$(git -C "$T/ask-repo" status --porcelain=v1 -- CLAUDE.md)" ] || fail "OMP auto-checkpoint consumed the CLAUDE.md edit"

printf 'parity-test: structural mirrors, lifecycle, checkpoint, command, push, and ask parity green\n'
