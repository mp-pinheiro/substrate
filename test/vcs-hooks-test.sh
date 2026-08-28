#!/usr/bin/env bash
# VCS-level enforcement, fully offline: git pre-commit must block slop written
# by anything (vim, scripts, other agents), pre-push must demand a green gate,
# and the jj push alias must gate before any ref reaches the remote.
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# scratch inits must never touch the live user harness (~/.claude, ~/.omp)
export SUBSTRATE_NO_USER_HARNESS=1

fail() { printf 'vcs-hooks-test FAIL: %s\n' "$1" >&2; exit 1; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

git init -q --bare "$T/git-origin.git"
mkdir -p "$T/git-repo"
(
    cd "$T/git-repo" || exit 9
    git init -q -b main .
    git config user.email substrate@localhost
    git config user.name substrate
    git remote add origin "$T/git-origin.git"
    mkdir -p components
    printf '#!/usr/bin/env bash\nset -euo pipefail\nls "$@"\n' > components/x.sh
    chmod +x components/x.sh
    env -u CI "$KIT_ROOT/bin/substrate" init --profile shell --from-worktree >/dev/null 2>&1 || fail "git: init failed"
    [ -x .git/hooks/pre-commit ] || fail "git: pre-commit not installed"
    [ -x .git/hooks/pre-push ] || fail "git: pre-push not installed"
    grep -q '^# substrate-managed$' .git/hooks/pre-commit || fail "git: pre-commit lacks marker"
    git add -A
    git commit -qm 'feat: seed' || fail "git: seed commit blocked by its own hook"
    out=$(env -u CI substrate-engine gate --update-baseline 2>&1) || fail "git: baseline not green: $out"
    git add -A
    git commit -qm 'chore: baseline' || fail "git: baseline commit blocked"

    printf '# now we check the thing\n# first we validate, then we proceed\n# finally we finish\n' >> components/x.sh
    before=$(git rev-list --count HEAD)
    git commit -qam 'feat: slop' 2>/dev/null && fail "git: slop commit not blocked by pre-commit"
    after=$(git rev-list --count HEAD)
    [ "$before" = "$after" ] || fail "git: blocked commit still landed"
    git checkout -q -- components/x.sh

    printf 'set -x\n' >> components/x.sh
    git commit -qam 'feat: clean change' || fail "git: clean commit wrongly blocked"

    printf 'plain text\n' > orphan.xyz
    git add orphan.xyz
    git commit -qm 'feat: orphan' || fail "git: orphan commit blocked by pre-commit (scan must not own unclaimed policy)"
    jq '.push_gate = false' substrate.json > "$T/push-gate-optout.json"
    mv "$T/push-gate-optout.json" substrate.json
    git push -q origin main 2>/dev/null && fail "git: push not blocked by red gate (unclaimed source)"
    git ls-remote --heads "$T/git-origin.git" | grep -q main && fail "git: ref reached remote despite red gate"
    git restore -- substrate.json

    git rm -q orphan.xyz
    git commit -qm 'fix: drop orphan' || fail "git: fix commit blocked"
    out=$(.substrate/push-gate.sh 2>&1) || fail "git: receipt seed failed: $out"
    grep -q 'green receipt recorded' <<< "$out" || fail "git: receipt seed was not recorded: $out"
    out=$(git push origin main 2>&1) || fail "git: push blocked despite green gate: $out"
    grep -q 'exact-state receipt accepted' <<< "$out" || fail "git: push did not reuse its exact receipt: $out"
    git ls-remote --heads "$T/git-origin.git" | grep -q main || fail "git: green push produced no remote ref"
) || exit 1

# Existing hooks must make bootstrap incomplete rather than silently shipping without enforcement.
mkdir -p "$T/custom-hook-repo"
(
    cd "$T/custom-hook-repo" || exit 9
    git init -q .
    git config user.email substrate@localhost
    git config user.name substrate
    printf '#!/usr/bin/env bash\necho custom\n' > .git/hooks/pre-commit
    chmod +x .git/hooks/pre-commit
    before=$(sha256sum .git/hooks/pre-commit)
    if env -u CI "$KIT_ROOT/bin/substrate" init --profile shell --from-worktree > bootstrap.out 2>&1; then
        fail "git: init reported success with an unchained custom pre-commit hook"
    fi
    [ "$before" = "$(sha256sum .git/hooks/pre-commit)" ] \
        || fail "git: custom pre-commit hook was modified"
    grep -q 'left untouched; chain it' bootstrap.out \
        || fail "git: custom hook refusal was not actionable"
) || exit 1

mkdir -p "$T/hooks-path-repo"
(
    cd "$T/hooks-path-repo" || exit 9
    git init -q .
    git config user.email substrate@localhost
    git config user.name substrate
    git config core.hooksPath .githooks
    mkdir .githooks
    printf '#!/usr/bin/env bash\necho custom\n' > .githooks/pre-push
    chmod +x .githooks/pre-push
    before=$(sha256sum .githooks/pre-push)
    if env -u CI "$KIT_ROOT/bin/substrate" init --profile shell --from-worktree > bootstrap.out 2>&1; then
        fail "git: init reported success with a custom hooksPath collision"
    fi
    [ "$before" = "$(sha256sum .githooks/pre-push)" ] \
        || fail "git: hooksPath pre-push hook was modified"
    [ -x .githooks/pre-commit ] || fail "git: effective hooksPath did not receive pre-commit"
) || exit 1

git init -q --bare "$T/jj-origin.git"
mkdir -p "$T/jj-repo"
(
    cd "$T/jj-repo" || exit 9
    jj git init --colocate >/dev/null 2>&1 || { printf 'vcs-hooks-test: jj unavailable — jj case skipped\n'; exit 0; }
    jj config set --repo user.name substrate >/dev/null 2>&1
    jj config set --repo user.email substrate@localhost >/dev/null 2>&1
    jj metaedit --update-author @ >/dev/null 2>&1
    git remote add origin "$T/jj-origin.git"
    mkdir -p components
    printf '#!/usr/bin/env bash\nset -euo pipefail\nls "$@"\n' > components/x.sh
    chmod +x components/x.sh
    env -u CI "$KIT_ROOT/bin/substrate" init --profile shell --from-worktree >/dev/null 2>&1 || fail "jj: init failed"
    jj config get aliases.push >/dev/null 2>&1 || fail "jj: push alias not configured"
    out=$(env -u CI substrate-engine gate --update-baseline 2>&1) || fail "jj: baseline not green: $out"
    jj commit -m 'feat: seed' >/dev/null 2>&1
    jj bookmark create main -r @- >/dev/null 2>&1
    printf 'plain text\n' > orphan.xyz
    cp substrate.json "$T/jj-substrate.json"
    jq '.push_gate = false' substrate.json > "$T/jj-push-gate-optout.json"
    mv "$T/jj-push-gate-optout.json" substrate.json
    out=$(env -u CI jj push -b main 2>&1)
    rc=$?
    [ "$rc" -ne 0 ] || fail "jj: push not blocked by red gate"
    grep -q 'push blocked' <<< "$out" || fail "jj: block message missing: $out"
    git ls-remote --heads "$T/jj-origin.git" | grep -q main && fail "jj: ref reached remote despite red gate"

    cp "$T/jj-substrate.json" substrate.json
    rm orphan.xyz
    printf 'printf "checkpointed\\n"\n' >> components/x.sh
    env -u CI substrate-engine checkpoint --message 'fix(shell): checkpoint jj change' --path components/x.sh >/dev/null 2>&1 \
        || fail "jj: checkpoint failed"
    commit=$(jq -r '.commit' .git/substrate/gate-receipt.json)
    bookmark=$(jq -r '.publicationBookmark' .git/substrate/gate-receipt.json)
    [ "$bookmark" = main ] || fail "jj: receipt publication bookmark is not main"
    [ "$(jj log -r "$bookmark" --no-graph -T commit_id)" = "$commit" ] \
        || fail "jj: local publication bookmark does not match receipt commit"
    if ! env -u CI substrate-engine receipt matches; then
        fail "jj: checkpoint gate receipt did not match current state"
    fi

    out=$(env -u CI jj push 2>&1) || fail "jj: green push failed: $out"
    grep -q 'exact-state receipt accepted' <<< "$out" || fail "jj: push did not reuse its exact receipt: $out"
    remote=$(git ls-remote "$T/jj-origin.git" "refs/heads/$bookmark" | cut -f1)
    [ "$remote" = "$commit" ] || fail "jj: remote bookmark does not match receipt commit"
    out=$(env -u CI jj push 2>&1) || fail "jj: unchanged push failed: $out"
    grep -q 'Nothing changed' <<< "$out" || fail "jj: unchanged push did not report Nothing changed: $out"
    base=$(jj log -r @- --no-graph -T commit_id)
    parent=$(jj log -r 'parents(main)' --no-graph -T commit_id)
    out=$(jj bookmark set --allow-backwards main -r "$parent" 2>&1)
    [ "$?" -eq 0 ] || fail "jj: could not move main behind checkpoint base: parent=$parent output=$out"
    [ "$(jj log -r main --no-graph -T commit_id)" != "$base" ] || fail "jj: main bookmark did not move behind base"
    jj bookmark create feature -r "$base" >/dev/null 2>&1
    jj config unset --repo experimental-advance-branches.enabled-branches >/dev/null 2>&1 || true
    printf 'printf "feature\\n"\n' >> components/x.sh
    env -u CI substrate-engine checkpoint --message 'fix(shell): checkpoint feature' --path components/x.sh >/dev/null 2>&1 \
        || fail "jj: feature checkpoint failed"
    feature_commit=$(jq -r '.commit' .git/substrate/gate-receipt.json)
    feature_bookmark=$(jq -r '.publicationBookmark' .git/substrate/gate-receipt.json)
    [ "$feature_bookmark" = feature ] \
        || fail "jj: feature bookmark was not selected: $feature_bookmark (main=$(jj log -r main --no-graph -T commit_id), feature=$(jj log -r feature --no-graph -T commit_id), base=$(jj log -r @- --no-graph -T commit_id))"
    [ "$(jj log -r feature --no-graph -T commit_id)" = "$feature_commit" ] \
        || fail "jj: feature bookmark does not match checkpoint commit"
    [ "$(jj log -r main --no-graph -T commit_id)" = "$parent" ] \
        || fail "jj: stale main bookmark moved unexpectedly"
    out=$(env -u CI jj push 2>&1) || fail "jj: feature push failed: $out"
    remote=$(git ls-remote "$T/jj-origin.git" "refs/heads/feature" | cut -f1)
    [ "$remote" = "$feature_commit" ] || fail "jj: feature remote does not match checkpoint commit"
) || exit 1

printf 'vcs-hooks-test: git commit/push gates and jj gated push green\n'
