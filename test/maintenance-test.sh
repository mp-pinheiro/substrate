#!/usr/bin/env bash
# End-to-end maintenance transactions across Git, Jujutsu, recovery, and external phases.
set -uo pipefail

export SUBSTRATE_ENGINE="${GOLDEN_ENGINE:-bash}"

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d)
ORIGINAL_HOME=$HOME
trap 'export HOME="$ORIGINAL_HOME"; rm -rf "$T"' EXIT

fail() { printf 'maintenance-test FAIL: %s\n' "$1" >&2; exit 1; }
configure_git() {
    git config user.email substrate@localhost
    git config user.name substrate
}
assert_exact_commit() {
    local receipt="$1" commit actual expected
    commit=$(jq -r '.repository.commit' "$receipt")
    actual=$(mktemp)
    expected=$(mktemp)
    git diff-tree --root --name-only -r --no-commit-id "$commit" -- | LC_ALL=C sort > "$actual" \
        || { rm -f "$actual" "$expected"; return 1; }
    jq -r '.repository.changedPaths[]' "$receipt" | LC_ALL=C sort > "$expected" \
        || { rm -f "$actual" "$expected"; return 1; }
    cmp -s "$actual" "$expected"
    local rc=$?
    rm -f "$actual" "$expected"
    return "$rc"
}

mkdir -p "$T/git-home" "$T/git-repo" "$T/remote.git"
export HOME="$T/git-home"
git init -q --bare "$T/remote.git"
cd "$T/git-repo" || exit 9
git init -q --initial-branch=main
configure_git
printf '#!/usr/bin/env bash\nprintf "clean\\n"\n' > app.sh
chmod +x app.sh
git add app.sh
git commit -qm 'chore: seed app'
git remote add origin "$T/remote.git"

"$KIT_ROOT/bin/substrate" bootstrap --profile shell --checkpoint --accept-baseline --repo-only > "$T/git-init.out" 2>&1 \
    || { cat "$T/git-init.out" >&2; fail "clean Git kickstart failed"; }
receipt=.git/substrate/maintenance-receipt.json
jq -e '.operation == "bootstrap" and .repository.status == "committed" and .noPush == true' "$receipt" >/dev/null \
    || fail "clean Git receipt is incomplete"
if git --git-dir="$T/remote.git" show-ref --verify refs/heads/main >/dev/null 2>&1; then
    fail "kickstart pushed to the remote"
fi

mkdir -p checks.d
printf '#!/usr/bin/env bash\nexit 0\n' > checks.d/85-local.sh
chmod +x checks.d/85-local.sh
git add checks.d/85-local.sh
git commit -q --no-verify -m 'chore: add local check'
printf 'dirty-user-work\n' >> app.sh
dirty_hash=$(sha256sum app.sh)
head_before=$(git rev-parse HEAD)
"$KIT_ROOT/bin/substrate" bootstrap --checkpoint --repo-only > "$T/git-dirty.out" 2>&1 \
    || { cat "$T/git-dirty.out" >&2; fail "dirty-work maintenance failed"; }
[ "$dirty_hash" = "$(sha256sum app.sh)" ] || fail "maintenance changed unrelated dirty work"
[ "$(git status --porcelain=v1 -- app.sh)" = ' M app.sh' ] || fail "maintenance absorbed unrelated dirty work"
[ "$head_before" != "$(git rev-parse HEAD)" ] || fail "managed maintenance paths were not committed"
assert_exact_commit "$receipt" || fail "Git maintenance commit differs from its receipt"
".substrate/push-gate.sh" > "$T/dirty-push-gate.out" 2>&1 \
    || fail "exact receipt rejected preserved dirty work"
grep -q 'exact-state receipt accepted' "$T/dirty-push-gate.out" \
    || fail "push guard did not reuse the maintenance receipt"
if git --git-dir="$T/remote.git" show-ref --verify refs/heads/main >/dev/null 2>&1; then
    fail "dirty-work maintenance pushed to the remote"
fi

baseline_hash=$(sha256sum substrate-baseline.json)
head_before=$(git rev-parse HEAD)
printf ' ' >> substrate-baseline.json
if "$KIT_ROOT/bin/substrate" bootstrap --checkpoint --repo-only > "$T/overlap.out" 2>&1; then
    fail "maintenance accepted a dirty baseline"
fi
grep -q 'overlaps dirty managed paths: substrate-baseline.json' "$T/overlap.out" \
    || fail "dirty overlap refusal was not actionable"
[ "$head_before" = "$(git rev-parse HEAD)" ] || fail "dirty overlap advanced the repository"
git restore substrate-baseline.json
[ "$baseline_hash" = "$(sha256sum substrate-baseline.json)" ] || fail "dirty overlap changed the baseline"

printf '#!/usr/bin/env bash\nexit 0\n' > checks.d/86-concurrent.sh
chmod +x checks.d/86-concurrent.sh
git add checks.d/86-concurrent.sh
git commit -q --no-verify -m 'chore: add concurrent check'
cat > "$T/drift.sh" <<'EOF'
#!/usr/bin/env bash
printf 'concurrent-drift\n' >> "$1/app.sh"
EOF
chmod +x "$T/drift.sh"
head_before=$(git rev-parse HEAD)
export SUBSTRATE_MAINTENANCE_TESTING=1
export SUBSTRATE_MAINTENANCE_TEST_HOOK="$T/drift.sh"
if "$KIT_ROOT/bin/substrate" bootstrap --checkpoint --repo-only > "$T/concurrent.out" 2>&1; then
    fail "maintenance accepted concurrent working-copy drift"
fi
unset SUBSTRATE_MAINTENANCE_TEST_HOOK SUBSTRATE_MAINTENANCE_TESTING
grep -q 'working copy changed while rendering maintenance candidate' "$T/concurrent.out" \
    || fail "concurrent drift refusal was not actionable"
[ "$head_before" = "$(git rev-parse HEAD)" ] || fail "concurrent drift advanced the repository"
[ ! -e .substrate/checks.d/86-concurrent.sh ] || fail "concurrent drift applied the candidate"
git restore app.sh

printf '#!/usr/bin/env bash\nexit 0\n' > checks.d/87-recovery.sh
chmod +x checks.d/87-recovery.sh
git add checks.d/87-recovery.sh
git commit -q --no-verify -m 'chore: add recovery check'
export SUBSTRATE_MAINTENANCE_TESTING=1
export SUBSTRATE_MAINTENANCE_FAIL_AFTER=1
if "$KIT_ROOT/bin/substrate" bootstrap --checkpoint --repo-only > "$T/incomplete.out" 2>&1; then
    fail "injected partial apply unexpectedly passed"
fi
unset SUBSTRATE_MAINTENANCE_FAIL_AFTER SUBSTRATE_MAINTENANCE_TESTING
jq -e '.repository.status == "incomplete"' "$receipt" >/dev/null \
    || fail "partial apply did not persist incomplete recovery state"
"$KIT_ROOT/bin/substrate" bootstrap --checkpoint --repo-only > "$T/recovery.out" 2>&1 \
    || { cat "$T/recovery.out" >&2; fail "incomplete transaction did not recover"; }
jq -e '.repository.status == "committed" and .repoRuntime.status == "passed"' "$receipt" >/dev/null \
    || fail "recovered transaction did not finish"
[ -z "$(git status --porcelain=v1 --untracked-files=all)" ] || fail "recovered transaction left pending work"
head_before=$(git rev-parse HEAD)
"$KIT_ROOT/bin/substrate" bootstrap --checkpoint --repo-only > "$T/idempotent.out" 2>&1 \
    || fail "idempotent maintenance rerun failed"
[ "$head_before" = "$(git rev-parse HEAD)" ] || fail "idempotent rerun created another commit"
jq -e '.repository.status == "committed" and (.repository.changedPaths | length) == 0' "$receipt" >/dev/null \
    || fail "idempotent rerun did not issue an exact no-change receipt"

printf '#!/usr/bin/env bash\nexit 0\n' > checks.d/88-commit-recovery.sh
chmod +x checks.d/88-commit-recovery.sh
git add checks.d/88-commit-recovery.sh
git commit -q --no-verify -m 'chore: add commit recovery check'
head_before=$(git rev-parse HEAD)
export SUBSTRATE_MAINTENANCE_TESTING=1
export SUBSTRATE_MAINTENANCE_FAIL_COMMIT=1
if "$KIT_ROOT/bin/substrate" bootstrap --checkpoint --repo-only > "$T/commit-fail.out" 2>&1; then
    fail "injected exact-commit failure unexpectedly passed"
fi
unset SUBSTRATE_MAINTENANCE_FAIL_COMMIT SUBSTRATE_MAINTENANCE_TESTING
jq -e '.repository.status == "incomplete"' "$receipt" >/dev/null \
    || fail "exact-commit failure did not persist resumable state"
[ "$head_before" = "$(git rev-parse HEAD)" ] || fail "failed exact commit advanced the repository"
[ -e .substrate/checks.d/88-commit-recovery.sh ] \
    || fail "exact-commit failure did not occur after managed apply"
"$KIT_ROOT/bin/substrate" bootstrap --checkpoint --repo-only > "$T/commit-recovery.out" 2>&1 \
    || { cat "$T/commit-recovery.out" >&2; fail "applied transaction did not resume its exact commit"; }
jq -e '.repository.status == "committed"' "$receipt" >/dev/null \
    || fail "exact-commit recovery did not finish"
[ "$head_before" != "$(git rev-parse HEAD)" ] || fail "exact-commit recovery did not advance the repository"
[ -z "$(git status --porcelain=v1 --untracked-files=all)" ] \
    || fail "exact-commit recovery left managed paths pending"

printf '#!/usr/bin/env bash\nexit 0\n' > checks.d/89-applied.sh
chmod +x checks.d/89-applied.sh
git add checks.d/89-applied.sh
git commit -q --no-verify -m 'chore: add applied-state check'
head_before=$(git rev-parse HEAD)
"$KIT_ROOT/bin/substrate" bootstrap --repo-only > "$T/applied-first.out" 2>&1 \
    || fail "non-checkpoint maintenance failed"
jq -e '.repository.status == "applied" and .repository.checkpointRequested == false' "$receipt" >/dev/null \
    || fail "non-checkpoint maintenance did not retain applied authorization"
[ "$head_before" = "$(git rev-parse HEAD)" ] || fail "non-checkpoint maintenance advanced the repository"
"$KIT_ROOT/bin/substrate" bootstrap --repo-only > "$T/applied-second.out" 2>&1 \
    || fail "repeated non-checkpoint maintenance failed"
jq -e '.repository.status == "applied"' "$receipt" >/dev/null \
    || fail "repeated non-checkpoint maintenance lost applied authorization"
[ "$head_before" = "$(git rev-parse HEAD)" ] || fail "repeated non-checkpoint maintenance advanced the repository"
"$KIT_ROOT/bin/substrate" bootstrap --checkpoint --repo-only > "$T/applied-checkpoint.out" 2>&1 \
    || fail "applied maintenance did not checkpoint on request"
jq -e '.repository.status == "committed"' "$receipt" >/dev/null \
    || fail "applied maintenance checkpoint was not recorded"
[ -z "$(git status --porcelain=v1 --untracked-files=all)" ] \
    || fail "applied maintenance checkpoint left managed paths pending"

for n in 1 2 3 4 5 6; do printf '# regression %s\n' "$n" >> app.sh; done
git add app.sh
git commit -q --no-verify -m 'chore: seed metric regression'
baseline_hash=$(sha256sum substrate-baseline.json)
head_before=$(git rev-parse HEAD)
if "$KIT_ROOT/bin/substrate" bootstrap --checkpoint --accept-baseline --repo-only > "$T/regression.out" 2>&1; then
    fail "existing baseline regression was accepted implicitly"
fi
grep -q 'beyond their grandfathered baseline' "$T/regression.out" \
    || fail "baseline regression refusal was not actionable"
[ "$baseline_hash" = "$(sha256sum substrate-baseline.json)" ] || fail "failed regression changed the baseline"
[ "$head_before" = "$(git rev-parse HEAD)" ] || fail "failed regression advanced the repository"

mkdir -p "$T/external-home" "$T/external-repo"
export HOME="$T/external-home"
cd "$T/external-repo" || exit 9
git init -q --initial-branch=main
configure_git
printf '#!/usr/bin/env bash\nprintf "external\\n"\n' > app.sh
chmod +x app.sh
git add app.sh
git commit -qm 'chore: seed external fixture'
export SUBSTRATE_MAINTENANCE_TESTING=1
export SUBSTRATE_MAINTENANCE_FAIL_PHASE=runtime
if "$KIT_ROOT/bin/substrate" bootstrap --profile shell --checkpoint --accept-baseline --repo-only > "$T/runtime-fail.out" 2>&1; then
    fail "injected repository runtime failure unexpectedly passed"
fi
unset SUBSTRATE_MAINTENANCE_FAIL_PHASE SUBSTRATE_MAINTENANCE_TESTING
external_receipt=.git/substrate/maintenance-receipt.json
jq -e '.repository.status == "committed" and .repoRuntime.status == "failed"' "$external_receipt" >/dev/null \
    || fail "repository runtime failure corrupted the repository phase"
external_commit=$(git rev-parse HEAD)
"$KIT_ROOT/bin/substrate" bootstrap --checkpoint --repo-only > "$T/runtime-repair.out" 2>&1 \
    || fail "repository runtime repair failed"
[ "$external_commit" = "$(git rev-parse HEAD)" ] || fail "runtime repair created another repository commit"
jq -e '.repoRuntime.status == "passed"' "$external_receipt" >/dev/null \
    || fail "repository runtime repair was not recorded"

export SUBSTRATE_MAINTENANCE_TESTING=1
export SUBSTRATE_MAINTENANCE_FAIL_PHASE=harness
if "$KIT_ROOT/bin/substrate" bootstrap --checkpoint > "$T/harness-fail.out" 2>&1; then
    fail "injected user harness failure unexpectedly passed"
fi
unset SUBSTRATE_MAINTENANCE_FAIL_PHASE SUBSTRATE_MAINTENANCE_TESTING
jq -e '.repository.status == "committed" and .userHarness.status == "failed"' "$external_receipt" >/dev/null \
    || fail "user harness failure corrupted the repository phase"
"$KIT_ROOT/bin/substrate" bootstrap --checkpoint > "$T/harness-repair.out" 2>&1 \
    || fail "user harness repair failed"
[ "$external_commit" = "$(git rev-parse HEAD)" ] || fail "harness repair created another repository commit"
jq -e '.userHarness.status == "passed"' "$external_receipt" >/dev/null \
    || fail "user harness repair was not recorded"
[ -f "$HOME/.local/state/substrate/harness-receipt.json" ] \
    || fail "user harness receipt was not written"

mkdir -p "$T/jj-home" "$T/jj-repo"
export HOME="$T/jj-home"
cd "$T/jj-repo" || exit 9
git init -q --initial-branch=main
configure_git
printf '#!/usr/bin/env bash\nprintf "clean\\n"\n' > app.sh
chmod +x app.sh
git add app.sh
git commit -qm 'chore: seed jj app'
jj git init --colocate >/dev/null 2>&1 || fail "Jujutsu fixture initialization failed"
jj config set --repo user.name 'Substrate Test'
jj config set --repo user.email substrate@localhost
"$KIT_ROOT/bin/substrate" bootstrap --profile shell --checkpoint --accept-baseline --repo-only > "$T/jj-init.out" 2>&1 \
    || { cat "$T/jj-init.out" >&2; fail "Jujutsu kickstart failed"; }
mkdir -p checks.d
printf '#!/usr/bin/env bash\nexit 0\n' > checks.d/85-jj.sh
chmod +x checks.d/85-jj.sh
jj commit -m 'chore: add jj local check' checks.d/85-jj.sh >/dev/null 2>&1 \
    || fail "Jujutsu source fixture commit failed"
printf 'dirty-jj-work\n' >> app.sh
jj_dirty_hash=$(sha256sum app.sh)
"$KIT_ROOT/bin/substrate" bootstrap --checkpoint --repo-only > "$T/jj-maintenance.out" 2>&1 \
    || { cat "$T/jj-maintenance.out" >&2; fail "Jujutsu maintenance failed"; }
jj_receipt=.git/substrate/maintenance-receipt.json
jq -e '.repository.status == "committed" and .repository.vcs == "jj" and .noPush == true' "$jj_receipt" >/dev/null \
    || fail "Jujutsu receipt is incomplete"
[ "$jj_dirty_hash" = "$(sha256sum app.sh)" ] || fail "Jujutsu maintenance changed unrelated work"
assert_exact_commit "$jj_receipt" || fail "Jujutsu maintenance commit differs from its receipt"
".substrate/maintenance-lib.sh" receipt-matches \
    || fail "Jujutsu exact receipt rejected preserved dirty work"

printf 'maintenance-test: Git/Jujutsu transactions, recovery, baseline, external phases, no-push green\n'
