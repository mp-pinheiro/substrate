#!/usr/bin/env bash
# Restructure transaction: allow-listed targets, atomic split/describe/squash,
# tree preservation, session integration, and the omp tool wrapper.
set -uo pipefail

fail() { printf 'restructure-test FAIL: %s\n' "$1" >&2; exit 1; }

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d) || fail "scratch dir"
trap 'rm -rf "$T"' EXIT
export SUBSTRATE_NO_USER_HARNESS=1
export HOME="$T/home"
mkdir -p "$HOME" "$T/jj-repo"

cd "$T/jj-repo" || exit 9
git init -q --initial-branch=main
jj config set --user user.name substrate >/dev/null 2>&1
jj config set --user user.email substrate@localhost >/dev/null 2>&1
jj git init --colocate . >/dev/null 2>&1 || fail "jj init failed"
"$KIT_ROOT/bin/substrate" init --profile shell --vcs jj >/dev/null 2>&1 || fail "substrate init failed"
.substrate/gate.sh --update-baseline >/dev/null 2>&1 || fail "baseline failed"
jj commit -m 'chore: initialize' >/dev/null 2>&1 || fail "seed commit failed"
seed_change=$(jj log -r @- --no-graph -T 'change_id')

printf '#!/usr/bin/env bash\nset -euo pipefail\nprintf "one\\n"\n' > one.sh
printf '#!/usr/bin/env bash\nset -euo pipefail\nprintf "two\\n"\n' > two.sh
chmod +x one.sh two.sh
.substrate/checkpoint.sh --message 'feat(shell): add both scripts' --path one.sh --path two.sh >/dev/null \
    || fail "checkpoint of the split fixture failed"
target_change=$(jj log -r @- --no-graph -T 'change_id')

if .substrate/restructure.sh --op split --revision "$seed_change" --path one.sh \
    --message 'refactor(shell): steal seed' --allow-change "$target_change" > "$T/out" 2>&1; then
    fail "restructure accepted a non-session revision"
fi
grep -q 'not an agent session-authored commit' "$T/out" || fail "allow-list rejection was not actionable"

if .substrate/restructure.sh --op split --revision "$target_change" --path one.sh \
    --message 'no conventional prefix' --allow-change "$target_change" > "$T/out" 2>&1; then
    fail "restructure accepted a non-conventional message"
fi
grep -q 'Conventional Commits' "$T/out" || fail "message rejection was not actionable"

.substrate/restructure.sh --op split --revision "$target_change" --path one.sh \
    --message 'refactor(shell): isolate one' --message2 'refactor(shell): keep two' \
    --allow-change "$target_change" --json > "$T/split.json" 2> "$T/split.err" \
    || fail "split transaction failed: $(cat "$T/split.err")"
receipt=$(tail -n 1 "$T/split.json")
jq -e '.status == "restructured" and .op == "split" and (.newChangeIds | length == 1)' <<< "$receipt" >/dev/null \
    || fail "split receipt is malformed: $receipt"
remainder_change=$(jq -r '.newChangeIds[0]' <<< "$receipt")
[ "$(jj log -r "$target_change" --no-graph -T 'description.first_line()')" = 'refactor(shell): isolate one' ] \
    || fail "split selected commit has the wrong message"
[ "$(jj log -r "$remainder_change" --no-graph -T 'description.first_line()')" = 'refactor(shell): keep two' ] \
    || fail "split remainder has the wrong message"
[ "$(jj diff -r "$target_change" --name-only)" = 'one.sh' ] || fail "split selected commit carries the wrong paths"
jj diff -r "$remainder_change" --name-only | grep -qx 'two.sh' || fail "split remainder lost two.sh"
jj diff -r "$remainder_change" --name-only | grep -qx 'one.sh' && fail "split remainder still carries one.sh"
[ -z "$(jj diff --name-only)" ] || fail "split left the working copy dirty"
jq -e '.operation == "restructure"' "$(git rev-parse --git-common-dir)/substrate/restructure-receipt.json" >/dev/null \
    || fail "restructure receipt file missing"

.substrate/restructure.sh --op describe --revision "$target_change" \
    --message 'refactor(shell): isolate one better' \
    --allow-change "$target_change" --allow-change "$remainder_change" >/dev/null 2>&1 \
    || fail "describe transaction failed"
[ "$(jj log -r "$target_change" --no-graph -T 'description.first_line()')" = 'refactor(shell): isolate one better' ] \
    || fail "describe did not rename the commit"

.substrate/restructure.sh --op squash --revision "$target_change" --into "$remainder_change" \
    --message 'refactor(shell): merge halves' \
    --allow-change "$target_change" --allow-change "$remainder_change" >/dev/null 2>&1 \
    || fail "squash transaction failed"
[ "$(jj log -r "$remainder_change" --no-graph -T 'description.first_line()')" = 'refactor(shell): merge halves' ] \
    || fail "squash did not apply the combined message"
jj diff -r "$remainder_change" --name-only | grep -qx 'one.sh' || fail "squash result lost one.sh"
jj diff -r "$remainder_change" --name-only | grep -qx 'two.sh' || fail "squash result lost two.sh"
[ -z "$(jj diff --name-only)" ] || fail "squash left the working copy dirty"

printf '{"session_id":"restructure-session"}\n' | .substrate/hooks/agent-lifecycle.sh start >/dev/null
printf '#!/usr/bin/env bash\nset -euo pipefail\nprintf "cli\\n"\n' > cli.sh
chmod +x cli.sh
printf '{"session_id":"restructure-session"}\n' | .substrate/hooks/agent-lifecycle.sh observe >/dev/null
.substrate/checkpoint.sh --session restructure-session --message 'feat(shell): add cli script' >/dev/null \
    || fail "session checkpoint failed"
session_state="$(git rev-parse --git-common-dir)/substrate/agent-sessions/restructure-session.json"
session_change=$(jq -r '.sessionChanges[0] // empty' "$session_state")
[ -n "$session_change" ] || fail "complete did not seed sessionChanges"
.substrate/restructure.sh --op describe --revision "$session_change" \
    --message 'feat(shell): add cli entrypoint' --session restructure-session >/dev/null 2>&1 \
    || fail "session-scoped describe failed"
[ "$(jj log -r "$session_change" --no-graph -T 'description.first_line()')" = 'feat(shell): add cli entrypoint' ] \
    || fail "session describe did not rename the commit"
[ "$(jq -r '.completedCommit' "$session_state")" = "$(jj log -r @- --no-graph -T 'commit_id')" ] \
    || fail "session state did not track the restructured revision"
printf '{"session_id":"restructure-session","stop_hook_active":false}\n' \
    | .substrate/hooks/agent-lifecycle.sh stop >/dev/null 2>&1 \
    || fail "stop stayed blocked after session restructure"
printf '{"session_id":"restructure-session"}\n' | .substrate/hooks/agent-lifecycle.sh end >/dev/null

mkdir -p "$T/git-only/.substrate"
cp "$KIT_ROOT/core/restructure.sh" "$T/git-only/.substrate/restructure.sh"
cp "$KIT_ROOT/core/receipt-lib.sh" "$T/git-only/.substrate/receipt-lib.sh"
chmod +x "$T/git-only/.substrate/restructure.sh"
git init -q "$T/git-only"
if "$T/git-only/.substrate/restructure.sh" --op describe --revision abc --message 'fix: x' \
    --allow-change abc > "$T/out" 2>&1; then
    fail "restructure ran outside a jj repository"
fi
grep -q 'requires a Jujutsu repository' "$T/out" || fail "git-repo rejection was not actionable"

cat > "$T/omp-restructure.ts" <<'TS'
import { writeFileSync } from "node:fs";

const { bootProbe } = await import(process.argv[3]);
const probe = await bootProbe(process.argv[2]);
const repo = process.argv[4];
const ctx = probe.context(repo);
await probe.callAll("session_start", {}, ctx);
const extraEvent = probe.writeEvent("extra-write", `${repo}/agent-extra.sh`);
await probe.callAll("tool_call", extraEvent, ctx);
writeFileSync(`${repo}/agent-extra.sh`, '#!/usr/bin/env bash\nset -euo pipefail\nprintf "extra\\n"\n', {
	mode: 0o755,
});
await probe.resultAll(extraEvent, ctx);
const checkpoint = await probe.tools.substrate_checkpoint.execute(
	"cp",
	{ message: "feat(shell): add extra script" },
	undefined,
	undefined,
	ctx,
);
const commit = checkpoint?.details?.commit ?? "";
const changeProc = Bun.spawnSync(["jj", "log", "-r", commit, "--no-graph", "-T", "change_id"], { cwd: repo });
const change = new TextDecoder().decode(changeProc.stdout).trim();
const restructure = await probe.tools.substrate_restructure.execute(
	"rs",
	{ op: "describe", revision: change, message: "feat(shell): rename extra script" },
	undefined,
	undefined,
	ctx,
);
const stop = (await probe.handlers.session_stop[0]({ stop_hook_active: false }, ctx)) ?? null;
console.log(JSON.stringify({ checkpoint, restructure, change, stop }));
TS

omp_results=$(bun "$T/omp-restructure.ts" "$KIT_ROOT/core/omp/substrate-quality.ts" \
    "$KIT_ROOT/test/lib/pi-probe.ts" "$T/jj-repo") \
    || fail "omp restructure probe failed"
jq -e '.checkpoint.details.status == "passed"' <<< "$omp_results" >/dev/null \
    || fail "omp checkpoint did not pass: $omp_results"
jq -e '.restructure.details.status == "restructured" and (.restructure.isError // false) == false' \
    <<< "$omp_results" >/dev/null || fail "omp restructure tool did not apply: $omp_results"
jq -e '.stop == null' <<< "$omp_results" >/dev/null \
    || fail "omp stop stayed blocked after restructure: $omp_results"
probe_change=$(jq -r '.change' <<< "$omp_results")
[ "$(jj log -r "$probe_change" --no-graph -T 'description.first_line()')" = 'feat(shell): rename extra script' ] \
    || fail "omp restructure did not rename the commit"

printf 'restructure-test: allow-list, split, describe, squash, session, omp tool green\n'
