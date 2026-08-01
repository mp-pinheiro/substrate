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
    env -u CI "$KIT_ROOT/bin/substrate" init --profile shell >/dev/null 2>&1 || fail "git: init failed"
    jq '.report.max_age_days = 0' substrate.json > s.tmp && mv s.tmp substrate.json
    [ -x .git/hooks/pre-commit ] || fail "git: pre-commit not installed"
    [ -x .git/hooks/pre-push ] || fail "git: pre-push not installed"
    grep -q '^# substrate-managed$' .git/hooks/pre-commit || fail "git: pre-commit lacks marker"
    git add -A
    git commit -qm 'feat: seed' || fail "git: seed commit blocked by its own hook"
    out=$(env -u CI .substrate/gate.sh --update-baseline 2>&1) || fail "git: baseline not green: $out"
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
    git push -q origin main 2>/dev/null && fail "git: push not blocked by red gate (unclaimed source)"
    git ls-remote --heads "$T/git-origin.git" | grep -q main && fail "git: ref reached remote despite red gate"

    git rm -q orphan.xyz
    git commit -qm 'fix: drop orphan' || fail "git: fix commit blocked"
    git push -q origin main || fail "git: push blocked despite green gate"
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
    if env -u CI "$KIT_ROOT/bin/substrate" init --profile shell > bootstrap.out 2>&1; then
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
    if env -u CI "$KIT_ROOT/bin/substrate" init --profile shell > bootstrap.out 2>&1; then
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
    git remote add origin "$T/jj-origin.git"
    mkdir -p components
    printf '#!/usr/bin/env bash\nset -euo pipefail\nls "$@"\n' > components/x.sh
    chmod +x components/x.sh
    env -u CI "$KIT_ROOT/bin/substrate" init --profile shell >/dev/null 2>&1 || fail "jj: init failed"
    jq '.report.max_age_days = 0' substrate.json > s.tmp && mv s.tmp substrate.json
    jj config get aliases.push >/dev/null 2>&1 || fail "jj: push alias not configured"
    out=$(env -u CI .substrate/gate.sh --update-baseline 2>&1) || fail "jj: baseline not green: $out"
    jj commit -m 'feat: seed' >/dev/null 2>&1
    jj bookmark create main -r @- >/dev/null 2>&1

    printf 'plain text\n' > orphan.xyz
    out=$(env -u CI jj push -b main 2>&1)
    rc=$?
    [ "$rc" -ne 0 ] || fail "jj: push not blocked by red gate"
    grep -q 'push blocked' <<< "$out" || fail "jj: block message missing: $out"
    git ls-remote --heads "$T/jj-origin.git" | grep -q main && fail "jj: ref reached remote despite red gate"

    rm orphan.xyz
    out=$(env -u CI jj push -b main 2>&1) || fail "jj: green push failed: $out"
    git ls-remote --heads "$T/jj-origin.git" | grep -q main || fail "jj: green push produced no remote ref"
) || exit 1

printf 'vcs-hooks-test: git commit/push gates and jj gated push green\n'
