#!/usr/bin/env bash
set -uo pipefail
export SUBSTRATE_ENGINE="${GOLDEN_ENGINE:-go}"

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"
export SUBSTRATE_NO_USER_HARNESS=1
mkdir -p "$HOME" "$T/git-repo"

fail() { printf 'checkpoint-test FAIL: %s\n' "$1" >&2; exit 1; }

cd "$T/git-repo" || exit 9
git init -q --initial-branch=main
git config user.name substrate
git config user.email substrate@localhost
printf '#!/usr/bin/env bash\nprintf "owned\\n"\n' > owned.sh
printf '#!/usr/bin/env bash\nprintf "user\\n"\n' > user.sh
chmod +x owned.sh user.sh
"$KIT_ROOT/bin/substrate" init --profile shell --vcs git --from-worktree >/dev/null 2>&1 || fail "Git init failed"
cat > .substrate/checks.d/58-baseline-probe.sh <<'SH'
#!/usr/bin/env bash
set -uo pipefail
source "$SUBSTRATE_DIR/gate-lib.sh"
while IFS=$'\t' read -r name value; do
    case "$name" in
        hi:*) metric_hi "$name" "$value" ;;
        *) metric "$name" "$value" ;;
    esac
done < <(jq -r 'to_entries[] | [.key, .value] | @tsv' "$REPO_ROOT/.git/probe-metrics.json")
SH
chmod +x .substrate/checks.d/58-baseline-probe.sh
printf '{"probe:alpha":10}\n' > .git/probe-metrics.json
git add -A
git commit -qm 'chore: initialize'
substrate-engine gate --update-baseline >/dev/null 2>&1 || fail "Git baseline failed"
git add substrate-baseline.json
git commit -qm 'chore: establish baseline'
[ -z "$(git status --porcelain=v1 --untracked-files=all)" ] || fail "probe seed left the tree dirty"
printf '{"probe:alpha":20}\n' > .git/probe-metrics.json
printf 'printf "grow\\n"\n' >> owned.sh
if substrate-engine checkpoint --message 'feat(x): grow' --path owned.sh > "$T/accept.out" 2>&1; then
    fail "checkpoint accepted an unreviewed metric regression"
fi
grep -q 'beyond their grandfathered baseline' "$T/accept.out" || fail "unreviewed regression rejection was not actionable"
if substrate-engine checkpoint --message 'feat(x): grow' --path owned.sh --accept-regression=probe:alpha > "$T/noreason.out" 2>&1; then
    fail "checkpoint accepted regression without --reason"
fi
grep -q 'requires --reason' "$T/noreason.out" || fail "missing reason rejection was not actionable"
before_msg=$(git log -1 --pretty=%s)
[ "$before_msg" = 'chore: establish baseline' ] || fail "rejected checkpoint advanced the commit log"
substrate-engine checkpoint --message 'feat(x): grow' --path owned.sh --accept-regression=probe:alpha --reason 'probe alpha regressed because the owned fixture grew intentionally' > "$T/accept.out" 2>&1 \
    || fail "keyed accept-regression checkpoint failed: $(cat "$T/accept.out")"
jq -e '.metrics["probe:alpha"] == 20' substrate-baseline.json >/dev/null \
    || fail "accepted regression did not persist the new floor"
git show --name-only --pretty= HEAD | grep -qx 'owned.sh' || fail "owned.sh missing from accepted-regression commit"
git show --name-only --pretty= HEAD | grep -qx 'substrate-baseline.json' || fail "baseline was not co-committed with the accepted regression"
[ -z "$(git status --porcelain=v1 --untracked-files=all)" ] || fail "accepted-regression checkpoint left pending work"
jq -e '.acceptedRegressions == ["probe:alpha"]' .git/substrate/gate-receipt.json >/dev/null \
    || fail "accepted regression key missing from the gate receipt"
if substrate-engine checkpoint --message 'feat(x): y' --path owned.sh --accept-regression > "$T/bare.out" 2>&1; then
    fail "checkpoint accepted the bare --accept-regression form"
fi
grep -q 'requires the keyed form' "$T/bare.out" || fail "bare accept-regression rejection was not actionable"
printf '{"session_id":"clean-session"}\n' | substrate-engine hook agent-lifecycle start >/dev/null 
printf '# now we check the thing\n# first we validate, then we proceed\n# finally we finish\n' >> owned.sh
printf '{"session_id":"clean-session"}\n' | substrate-engine hook agent-lifecycle observe >/dev/null
if printf '{"session_id":"clean-session","stop_hook_active":false}\n' \
    | substrate-engine hook agent-lifecycle stop > "$T/stop.out" 2>&1; then
    fail "Claude stop accepted red owned work"
fi
grep -q 'completion blocked' "$T/stop.out" || fail "Claude stop rejection was not actionable"
grep -q 'Automatic checkpoint failed' "$T/stop.out" || fail "auto-checkpoint failure was not surfaced"
git checkout -q -- owned.sh
printf 'printf "changed\\n"\n' >> owned.sh
printf '{"session_id":"clean-session"}\n' | substrate-engine hook agent-lifecycle observe >/dev/null
printf '{"session_id":"clean-session","stop_hook_active":false}\n' \
    | substrate-engine hook agent-lifecycle stop > "$T/stop.out" 2>&1 \
    || fail "Claude stop did not auto-checkpoint green owned work"
grep -q 'auto-checkpoint' "$T/stop.out" || fail "auto-checkpoint success was not surfaced"
jq -e '.status == "passed" and .source == "checkpoint" and .reusable == true' \
    .git/substrate/gate-receipt.json >/dev/null || fail "Git checkpoint receipt is not reusable"
[ -z "$(git status --porcelain=v1 --untracked-files=all)" ] || fail "Git auto-checkpoint left pending work"
[ "$(git log -1 --pretty=%s)" = 'chore(agent): checkpoint owned work at session stop' ] \
    || fail "Git auto-checkpoint wrote the wrong commit"
printf '{"session_id":"clean-session"}\n' | substrate-engine hook agent-lifecycle end >/dev/null
[ ! -e .git/substrate/agent-sessions/clean-session.json ] || fail "Claude session state survived SessionEnd"

printf 'printf "unowned\\n"\n' >> user.sh
printf '{"session_id":"dirty-session"}\n' | substrate-engine hook agent-lifecycle start >/dev/null
printf 'printf "agent\\n"\n' >> owned.sh
printf '{"session_id":"dirty-session"}\n' | substrate-engine hook agent-lifecycle observe >/dev/null
before=$(git rev-parse HEAD)
substrate-engine checkpoint --session dirty-session --message 'fix(shell): checkpoint owned beside unowned' > "$T/checkpoint.out" 2>&1 \
    || fail "path-scoped checkpoint did not commit owned work beside unowned changes"
[ "$before" != "$(git rev-parse HEAD)" ] || fail "path-scoped checkpoint did not advance HEAD"
git show --name-only --pretty=format: HEAD | grep -qx 'owned.sh' || fail "owned.sh missing from path-scoped commit"
git show --name-only --pretty=format: HEAD | grep -qx 'user.sh' && fail "unowned user.sh leaked into the agent commit"
[ -n "$(git status --porcelain=v1 -- user.sh)" ] || fail "unowned user.sh vanished after path-scoped checkpoint"
grep -q 'unowned pending paths in place' "$T/checkpoint.out" || fail "leftover paths were not surfaced"
jq -e '.reusable == false' .git/substrate/gate-receipt.json >/dev/null \
    || fail "path-scoped receipt on a dirty tree claims reusability"
printf '{"session_id":"dirty-session","stop_hook_active":false}\n' \
    | substrate-engine hook agent-lifecycle stop >/dev/null 2>&1 \
    || fail "Claude stop stayed blocked after path-scoped checkpoint of owned work"
printf '{"session_id":"dirty-session"}\n' | substrate-engine hook agent-lifecycle end >/dev/null

printf 'printf "agent\\n"\n' >> owned.sh
if substrate-engine checkpoint --message 'fix(shell): reject unpending path' --path owned.sh --path ghost.sh > "$T/checkpoint.out" 2>&1; then
    fail "checkpoint accepted a path that is not pending"
fi
grep -q 'not pending working-copy changes' "$T/checkpoint.out" || fail "not-pending rejection was not actionable"
substrate-engine checkpoint --message 'fix(shell): checkpoint explicit subset' --path owned.sh > "$T/checkpoint.out" 2>&1 \
    || fail "explicit-path subset checkpoint failed"
[ -n "$(git status --porcelain=v1 -- user.sh)" ] || fail "explicit subset consumed unowned user.sh"
git show --name-only --pretty=format: HEAD | grep -qx 'owned.sh' || fail "owned.sh missing from explicit subset commit"
git checkout -q -- user.sh

jq '.metrics.protected_probe = 1' substrate-baseline.json > baseline.tmp 
mv baseline.tmp substrate-baseline.json
if substrate-engine checkpoint --message 'fix(shell): reject governed path' --path substrate-baseline.json > "$T/checkpoint.out" 2>&1; then
    fail "checkpoint accepted a governed baseline path"
fi
grep -q 'baseline changes only via the gate' "$T/checkpoint.out" || fail "governed path rejection was not actionable"
git restore -- substrate-baseline.json

mkdir -p "$T/jj-repo"
cd "$T/jj-repo" || exit 9
jj config set --user user.name substrate >/dev/null 2>&1
jj config set --user user.email substrate@localhost >/dev/null 2>&1
git init -q --initial-branch=main
jj git init --colocate . >/dev/null 2>&1 || fail "Jujutsu init failed"
printf '#!/usr/bin/env bash\nprintf "owned\\n"\n' > owned.sh
chmod +x owned.sh
"$KIT_ROOT/bin/substrate" init --profile shell --vcs jj >/dev/null 2>&1 || fail "Jujutsu substrate init failed"
substrate-engine gate --update-baseline >/dev/null 2>&1 || fail "Jujutsu baseline failed"
jj commit -m 'chore: initialize' >/dev/null 2>&1 || fail "Jujutsu seed commit failed"
printf 'printf "changed\\n"\n' >> owned.sh
substrate-engine checkpoint --message 'fix(shell): checkpoint jj work' --path owned.sh >/dev/null \
    || fail "Jujutsu checkpoint failed"
[ -z "$(jj diff --name-only)" ] || fail "Jujutsu checkpoint left pending work"
[ "$(jj log -r @- --no-graph -T description)" = 'fix(shell): checkpoint jj work' ] \
    || fail "Jujutsu checkpoint wrote the wrong commit"
commit=$(jj log -r @- --no-graph -T commit_id)
jq -e --arg commit "$commit" '.commit == $commit and .vcs == "jj" and .reusable == true' \
    .git/substrate/gate-receipt.json >/dev/null || fail "Jujutsu checkpoint receipt is not reusable"

printf 'checkpoint-test: lifecycle, ownership, governed paths, Git, Jujutsu green\n'
