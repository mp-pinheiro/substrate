#!/usr/bin/env bash
# One command must kickstart a fresh repo, then synchronize every Substrate-owned
# artifact without changing repo-owned configuration or generated-tool settings.
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SUBSTRATE_NO_USER_HARNESS=1

fail() { printf 'bootstrap-test FAIL: %s\n' "$1" >&2; exit 1; }

managed_matches() {
    local installed="$1" source="$2" first body
    IFS= read -r first < "$installed"
    [ "$first" = "# substrate-managed" ] || return 1
    body=$(mktemp) || return 1
    { IFS= read -r _; cat; } < "$installed" > "$body"
    cmp -s "$body" "$source"
    local rc=$?
    rm -f "$body"
    return "$rc"
}

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/missing-profile"
cd "$T/missing-profile" || exit 9
git init -q .
if "$KIT_ROOT/bin/substrate" bootstrap > bootstrap.out 2>&1; then
    fail "fresh bootstrap passed without --profile"
fi
grep -q 'bootstrap requires --profile' bootstrap.out \
    || fail "fresh bootstrap did not explain the profile requirement"

mkdir -p "$T/repo"
cd "$T/repo" || exit 9
git init -q .
git config user.email substrate@localhost
git config user.name substrate
mkdir -p .claude
printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash repo-hook.sh"},{"type":"command","command":"bash \\\"${CLAUDE_PROJECT_DIR:-.}/.substrate/hooks/retired-hook.sh\\\""}]}]}}\n' > .claude/settings.json
chmod 444 .claude/settings.json
mkdir -p .claude/skills/context-pack .omp/agents
: > .claude/agents
printf 'repo-owned skill\n' > .claude/skills/context-pack/SKILL.md
printf 'repo-owned agent\n' > .omp/agents/enemy.md
git add -A
git commit -qm 'chore: seed repository-owned files'

"$KIT_ROOT/bin/substrate" bootstrap --profile shell --checkpoint --accept-baseline --repo-only >/dev/null 2>&1 \
    || fail "fresh bootstrap failed"
[ -f .substrate/VERSION ] || fail ".substrate was not vendored"
grep -q 'substrate-engine hook' .claude/settings.json || fail "engine-form hooks were not installed"
[ -x .substrate/install-jj.sh ] || fail "Jujutsu installer was not vendored"
grep -q 'repo-hook.sh' .claude/settings.json || fail "repo hook was dropped"
grep -q 'retired-hook.sh' .claude/settings.json \
    && fail "retired managed hook survived mixed-group synchronization"
grep -qx '# substrate-managed' .github/workflows/substrate-gate.yml \
    || fail "gate workflow is not marked as managed"
managed_matches .github/workflows/substrate-report.yml "$KIT_ROOT/core/ci/github-report.yml" \
    || fail "report workflow does not match its source"
grep -q 'shellcheck zsh' .github/workflows/substrate-gate.yml \
    || fail "shell profile toolchain missing from gate workflow"
grep -q 'apt-get install -y -qq --no-install-recommends sudo jq unzip file locales' .github/workflows/substrate-gate.yml \
    || fail "Forgejo container prerequisites missing from gate workflow"
prereq_match=$(grep -n -m1 'name: Install container prerequisites' .github/workflows/substrate-gate.yml)
gitleaks_match=$(grep -n -m1 'name: Install Gitleaks' .github/workflows/substrate-gate.yml)
[ -n "$prereq_match" ] && [ -n "$gitleaks_match" ] \
    || fail "Forgejo prerequisite ordering anchors missing"
prereq_line=${prereq_match%%:*}
gitleaks_line=${gitleaks_match%%:*}
[ "$prereq_line" -lt "$gitleaks_line" ] \
    || fail "Forgejo container prerequisites run after Gitleaks installation"
grep -q '\.substrate/install-jj\.sh' .github/workflows/substrate-gate.yml \
    || fail "core Jujutsu installer missing from gate workflow"
grep -q 'name: Resolve Substrate kit revision' .github/workflows/substrate-gate.yml \
    || fail "Substrate kit revision step missing from gate workflow"
grep -q 'repository: .*github.repository_owner.*/substrate' .github/workflows/substrate-gate.yml \
    || fail "Substrate kit checkout missing from gate workflow"
grep -q 'ref: .*steps.substrate-kit.outputs.revision' .github/workflows/substrate-gate.yml \
    || fail "Substrate kit checkout is not pinned to vendor revision"
grep -q 'go-version-file: .substrate-kit/go.mod' .github/workflows/substrate-gate.yml \
    || fail "Substrate kit Go module missing from gate workflow"
grep -q 'working-directory: .substrate-kit' .github/workflows/substrate-gate.yml \
    || fail "Substrate engine build directory missing from gate workflow"
grep -q 'name: Build substrate engine from kit' .github/workflows/substrate-gate.yml \
    || fail "Substrate kit engine build step missing from gate workflow"
grep -q 'mkdir -p "$GITHUB_WORKSPACE/build"' .github/workflows/substrate-gate.yml \
    || fail "Substrate engine output directory missing from gate workflow"
grep -q 'GITHUB_WORKSPACE/build/substrate-engine' .github/workflows/substrate-gate.yml \
    || fail "Substrate engine output path missing from gate workflow"
! grep -qx '          go-version-file: go.mod' .github/workflows/substrate-gate.yml \
    || fail "consumer workflow still references root go.mod"
kit_step=$(grep -n -m1 'name: Resolve Substrate kit revision' .github/workflows/substrate-gate.yml)
checkout_step=$(grep -n -m1 'repository: .*github.repository_owner.*/substrate' .github/workflows/substrate-gate.yml)
build_step=$(grep -n -m1 'name: Build substrate engine from kit' .github/workflows/substrate-gate.yml)
kit_line=${kit_step%%:*}
checkout_line=${checkout_step%%:*}
build_line=${build_step%%:*}
[ "$kit_line" -lt "$checkout_line" ] && [ "$checkout_line" -lt "$build_line" ] \
    || fail "Substrate kit workflow steps are out of order"
! grep -q '^permissions:' .github/workflows/substrate-gate.yml \
    || fail "consumer gate workflow carries unsupported Forgejo permissions"
! grep -q '^permissions:' .github/workflows/substrate-report.yml \
    || fail "consumer report workflow carries unsupported Forgejo permissions"
grep -q 'echo "$GITHUB_WORKSPACE/build" >> "$GITHUB_PATH"' .github/workflows/substrate-gate.yml \
    || fail "Substrate engine path is not exported to later steps"
grep -q 'bookworm-backports.list' .github/workflows/substrate-gate.yml \
    || fail "Forgejo workflow does not provision the required Git backport source"
grep -q 'apt-get install -y -qq --no-install-recommends -t bookworm-backports git' .github/workflows/substrate-gate.yml \
    || fail "Forgejo workflow does not provision Git for Jujutsu"
grep -q 'Git >= 2.41 is required by the pinned Jujutsu' .github/workflows/substrate-gate.yml \
    || fail "Forgejo workflow does not enforce the Jujutsu Git requirement"
cmp -s .claude/skills/review/SKILL.md "$KIT_ROOT/skills/review/SKILL.md" \
    || fail "Claude skill was not installed"
cmp -s .omp/skills/review/SKILL.md "$KIT_ROOT/skills/review/SKILL.md" \
    || fail "omp skill was not installed"
cmp -s .claude/agents/explorer.md "$KIT_ROOT/agents/claude/explorer.md" \
    || fail "Claude agent was not installed"
cmp -s .omp/agents/explorer.md "$KIT_ROOT/agents/omp/explorer.md" \
    || fail "omp agent was not installed"
grep -q '^repo-owned skill$' .claude/skills/context-pack/SKILL.md \
    || fail "repo-owned skill was overwritten"
grep -q '^repo-owned agent$' .omp/agents/enemy.md \
    || fail "repo-owned agent was overwritten"
[ "$(stat -c '%a' .claude/settings.json)" = "444" ] \
    || fail "Claude settings mode changed during atomic synchronization"
cp .claude/settings.json "$T/settings.saved"
jq '.note = "protect-paths"
    | .hooks.PreToolUse |= map(
        if any(.hooks[]?; (.command // "") | contains("protect-paths"))
        then .matcher = "Read" else . end
    )' .claude/settings.json > "$T/settings.malformed"
mv "$T/settings.malformed" .claude/settings.json
out=$("$KIT_ROOT/bin/substrate" doctor 2>&1)
grep -q 'hook registration missing or malformed' <<< "$out" \
    || fail "doctor accepted a filename mention under the wrong matcher"
mv "$T/settings.saved" .claude/settings.json
chmod 444 .claude/settings.json
printf '{"metrics":{"sentinel":1}}\n' > substrate-baseline.json
dirty_baseline_before=$(sha256sum substrate-baseline.json)
if "$KIT_ROOT/bin/substrate" bootstrap --checkpoint --repo-only > bootstrap.out 2>&1; then
    fail "bootstrap absorbed an uncommitted baseline"
fi
grep -q 'overlaps dirty managed paths: substrate-baseline.json' bootstrap.out \
    || fail "dirty baseline refusal was not actionable"
[ "$dirty_baseline_before" = "$(sha256sum substrate-baseline.json)" ] \
    || fail "dirty baseline refusal changed the file"
git restore substrate-baseline.json


config_before=$(sha256sum substrate.json)
cp substrate-baseline.json "$T/baseline.before"
printf '{"servers":{},"idleTimeoutMs":1}\n' > .omp/lsp.json
lsp_before=$(sha256sum .omp/lsp.json)
mkdir -p checks.d
printf '#!/usr/bin/env bash\nexit 0\n' > checks.d/85-local.sh
chmod +x checks.d/85-local.sh
printf '# stale engine\n' > .substrate/report.sh
printf '# substrate-managed\nstale\n' > .github/workflows/substrate-gate.yml
printf '# substrate-managed\nstale\n' > .github/workflows/substrate-report.yml
printf 'stale skill\n' > .omp/skills/review/SKILL.md
printf 'stale agent\n' > .claude/agents/explorer.md
mv .omp/skills/review/.substrate-managed.json .omp/skills/review/.substrate-managed
mv .claude/agents/explorer.md.substrate-managed.json .claude/agents/explorer.md.substrate-managed
printf 'user addition inside managed root\n' > .omp/skills/review/local.txt
mkdir -p .omp/skills/retired
printf 'retired skill\n' > .omp/skills/retired/SKILL.md
printf '{"managed_by":"substrate"}\n' > .omp/skills/retired/.substrate-managed.json
printf 'retired agent\n' > .claude/agents/retired.md
printf '{"managed_by":"substrate"}\n' > .claude/agents/retired.md.substrate-managed.json
rm -f bootstrap.out
git add -A
git commit -q --no-verify -m 'chore: seed legacy managed state'

"$KIT_ROOT/bin/substrate" bootstrap --checkpoint --repo-only > bootstrap.out 2>&1 \
    || { cat bootstrap.out >&2; fail "existing-repo synchronization failed"; }
cmp -s .substrate/report.sh "$KIT_ROOT/core/report.sh" \
    || fail "vendored report did not synchronize"
managed_matches .github/workflows/substrate-report.yml "$KIT_ROOT/core/ci/github-report.yml" \
    || fail "managed report workflow did not synchronize"
grep -q 'shellcheck zsh' .github/workflows/substrate-gate.yml \
    || fail "managed gate workflow did not re-render"
cmp -s checks.d/85-local.sh .substrate/checks.d/85-local.sh \
    || fail "repo-local check did not synchronize"
[ "$config_before" = "$(sha256sum substrate.json)" ] \
    || fail "bootstrap changed substrate.json"
jq -e -s '.[0].metrics as $old
    | .[1].metrics
    | all(to_entries[]; .value <= ($old[.key] // .value))' \
    "$T/baseline.before" substrate-baseline.json >/dev/null \
    || fail "bootstrap checkpoint loosened the baseline"
[ "$lsp_before" = "$(sha256sum .omp/lsp.json)" ] \
    || fail "bootstrap changed repo-owned LSP config"
grep -q 'repo-hook.sh' .claude/settings.json \
    || fail "repo hook was dropped during synchronization"
cmp -s .omp/skills/review/SKILL.md "$KIT_ROOT/skills/review/SKILL.md" \
    || fail "managed skill did not synchronize"
cmp -s .claude/agents/explorer.md "$KIT_ROOT/agents/claude/explorer.md" \
    || fail "managed agent did not synchronize"
jq -e '.managed_by == "substrate"' .omp/skills/review/.substrate-managed.json >/dev/null \
    || fail "managed skill marker did not migrate to JSON"
jq -e '.managed_by == "substrate"' .claude/agents/explorer.md.substrate-managed.json >/dev/null \
    || fail "managed agent marker did not migrate to JSON"
[ ! -e .omp/skills/review/local.txt ] \
    || fail "managed skill root retained a user-added file despite full ownership"
[ ! -e .omp/skills/retired ] || fail "retired managed skill survived synchronization"
[ ! -e .claude/agents/retired.md ] || fail "retired managed agent survived synchronization"
[ ! -e .claude/agents/retired.md.substrate-managed.json ] \
    || fail "retired managed agent marker survived synchronization"
[ ! -e .omp/skills/review/.substrate-managed ] \
    || fail "legacy skill marker survived migration"
[ ! -e .claude/agents/explorer.md.substrate-managed ] \
    || fail "legacy agent marker survived migration"
grep -q '^repo-owned skill$' .claude/skills/context-pack/SKILL.md \
    || fail "repo-owned skill changed during synchronization"
grep -q '^repo-owned agent$' .omp/agents/enemy.md \
    || fail "repo-owned agent changed during synchronization"

printf 'repo-owned workflow\n' > .github/workflows/substrate-report.yml
git add .github/workflows/substrate-report.yml
git commit -q --no-verify -m 'chore: seed repo-owned workflow'
if "$KIT_ROOT/bin/substrate" bootstrap > bootstrap.out 2>&1; then
    fail "bootstrap adopted an unmarked workflow without --force"
fi
grep -q 'not substrate-managed' bootstrap.out \
    || fail "unmanaged workflow refusal was not actionable"
grep -q '^repo-owned workflow$' .github/workflows/substrate-report.yml \
    || fail "unmanaged workflow was modified"
"$KIT_ROOT/bin/substrate" bootstrap --force --checkpoint --repo-only >/dev/null 2>&1 \
    || fail "forced workflow adoption failed"
managed_matches .github/workflows/substrate-report.yml "$KIT_ROOT/core/ci/github-report.yml" \
    || fail "forced workflow adoption did not synchronize"
cat > .github/workflows/substrate-report.yml <<'EOF'
# substrate-repo-owned
name: custom-workflow
on: [push]
jobs:
  noop:
    runs-on: ubuntu-latest
    steps:
      - run: "true"
EOF
git add .github/workflows/substrate-report.yml
git commit -q --no-verify -m 'chore: mark repo-owned workflow'
"$KIT_ROOT/bin/substrate" bootstrap --checkpoint --repo-only >/dev/null 2>&1 \
    || fail "explicitly repo-owned workflow made bootstrap incomplete"
grep -q '^name: custom-workflow$' .github/workflows/substrate-report.yml \
    || fail "explicitly repo-owned workflow was modified"

if "$KIT_ROOT/bin/substrate" bootstrap --profile lua > bootstrap.out 2>&1; then
    fail "bootstrap accepted profiles that disagree with substrate.json"
fi
grep -q 'requested profiles differ' bootstrap.out \
    || fail "profile mismatch refusal was not actionable"

# A non-regular managed file must fail closed and remain untouched.
rm -f .omp/agents/explorer.md
mkdir .omp/agents/explorer.md
if "$KIT_ROOT/bin/substrate" bootstrap > bootstrap.out 2>&1; then
    fail "bootstrap accepted a directory at a managed file path"
fi
[ -d .omp/agents/explorer.md ] || fail "non-regular managed path was destructively replaced"
rm -rf .omp/agents/explorer.md
rm -f .omp/agents/explorer.md.substrate-managed.json
"$KIT_ROOT/bin/substrate" bootstrap --checkpoint --repo-only >/dev/null 2>&1 \
    || fail "managed agent recovery failed"

# A symlinked ownership marker cannot authorize deletion.
mkdir -p .omp/skills/retired-link
printf 'do not delete\n' > .omp/skills/retired-link/SKILL.md
printf '{"managed_by":"substrate"}\n' > "$T/external-marker.json"
ln -s "$T/external-marker.json" .omp/skills/retired-link/.substrate-managed.json
if "$KIT_ROOT/bin/substrate" bootstrap > bootstrap.out 2>&1; then
    fail "bootstrap trusted a symlinked ownership marker"
fi
[ -f .omp/skills/retired-link/SKILL.md ] || fail "symlink-marked skill was deleted"
grep -q 'managed_by' "$T/external-marker.json" || fail "external marker target changed"
rm -rf .omp/skills/retired-link

# A second-leg install failure restores the previous managed file and marker.
(
    info() { :; }
    success() { :; }
    warn() { :; }
    die() { return 1; }
    profile_dir() { return 1; }
    # shellcheck source=../core/install-lib.sh
    source "$KIT_ROOT/core/install-lib.sh"
    TX="$T/asset-transaction"
    mkdir -p "$TX"
    printf 'new agent\n' > "$TX/source.md"
    printf 'old agent\n' > "$TX/agent.md"
    printf '{"managed_by":"substrate","sentinel":"old"}\n' > "$TX/agent.md.substrate-managed.json"
    old_file=$(sha256sum "$TX/agent.md")
    old_marker=$(sha256sum "$TX/agent.md.substrate-managed.json")
    mv() {
        local destination=""
        for destination in "$@"; do :; done
        if [ "$destination" = "$TX/agent.md.substrate-managed.json" ] \
            && [ "$(basename "$1")" = "marker" ]; then
            return 1
        fi
        command mv "$@"
    }
    if sync_managed_asset_file "$TX/source.md" "$TX/agent.md" "transaction probe"; then
        fail "managed file transaction ignored marker-install failure"
    fi
    [ "$old_file" = "$(sha256sum "$TX/agent.md")" ] \
        || fail "managed file transaction did not restore prior content"
    [ "$old_marker" = "$(sha256sum "$TX/agent.md.substrate-managed.json")" ] \
        || fail "managed file transaction did not preserve prior marker"
)

# An internal symlinked asset root resolves to its canonical repo path.
mkdir -p "$T/internal-link-repo/.claude" "$T/internal-link-repo/shared/skills/context-pack"
cd "$T/internal-link-repo" || exit 9
git init -q .
git config user.email substrate@localhost
git config user.name substrate
printf 'repo-owned skill\n' > shared/skills/context-pack/SKILL.md
ln -s ../shared/skills .claude/skills
git add -A
git commit -qm 'chore: seed internal asset symlink'
"$KIT_ROOT/bin/substrate" bootstrap --profile shell --checkpoint --accept-baseline --repo-only >/dev/null 2>&1 \
    || fail "bootstrap rejected an internal symlinked asset root"
[ -L .claude/skills ] || fail "bootstrap replaced an internal asset-root symlink"
grep -q '^repo-owned skill$' shared/skills/context-pack/SKILL.md \
    || fail "bootstrap changed a repo-owned skill behind an internal symlink"
cmp -s shared/skills/review/SKILL.md "$KIT_ROOT/skills/review/SKILL.md" \
    || fail "bootstrap did not synchronize through the canonical internal asset path"

# An asset-root symlink outside the repository remains fail-closed.
mkdir -p "$T/asset-escape/.claude" "$T/outside-skills"
printf 'sentinel\n' > "$T/outside-skills/sentinel"
cd "$T/asset-escape" || exit 9
git init -q .
git config user.email substrate@localhost
git config user.name substrate
ln -s "$T/outside-skills" .claude/skills
git add .claude/skills
git commit -qm 'chore: seed escaping asset symlink'
if "$KIT_ROOT/bin/substrate" bootstrap --profile shell --checkpoint --accept-baseline --repo-only > bootstrap.out 2>&1; then
    fail "bootstrap followed an escaping asset-root symlink"
fi
[ ! -e "$T/outside-skills/review" ] || fail "bootstrap wrote assets outside the repository"
grep -q '^sentinel$' "$T/outside-skills/sentinel" || fail "outside asset sentinel changed"

# Repository writes cannot traverse a symlinked destination root.
mkdir -p "$T/outside" "$T/symlink-repo"
printf 'sentinel\n' > "$T/outside/sentinel"
cd "$T/symlink-repo" || exit 9
git init -q .
git config user.email substrate@localhost
git config user.name substrate
ln -s "$T/outside" .github
git add .github
git commit -qm 'chore: seed escaping destination symlink'
if "$KIT_ROOT/bin/substrate" bootstrap --profile shell --checkpoint --accept-baseline --repo-only > bootstrap.out 2>&1; then
    fail "bootstrap followed a symlinked .github destination"
fi
[ ! -e "$T/outside/workflows" ] || fail "bootstrap wrote workflows outside the repository"
grep -q '^sentinel$' "$T/outside/sentinel" || fail "outside sentinel changed"

# Bootstrap and init share update's downgrade guard.
mkdir -p "$T/newer-repo"
cd "$T/newer-repo" || exit 9
git init -q .
git config user.email substrate@localhost
git config user.name substrate
"$KIT_ROOT/bin/substrate" bootstrap --profile shell --checkpoint --accept-baseline --repo-only >/dev/null 2>&1 \
    || fail "newer-version fixture bootstrap failed"
printf '9.9.9\n' > .substrate/VERSION
if "$KIT_ROOT/bin/substrate" bootstrap > bootstrap.out 2>&1; then
    fail "bootstrap silently downgraded a newer vendored core"
fi
grep -q 'newer than kit' bootstrap.out || fail "downgrade refusal was not actionable"
grep -q '^9.9.9$' .substrate/VERSION || fail "downgrade refusal still changed the core"
"$KIT_ROOT/bin/substrate" bootstrap --force --checkpoint --repo-only >/dev/null 2>&1 \
    || fail "explicit forced downgrade failed"
cmp -s .substrate/VERSION "$KIT_ROOT/VERSION" || fail "forced downgrade did not install the kit version"

# Invoking the CLI through a user-local symlink must still resolve the source kit.
mkdir -p "$T/symlink-bin" "$T/symlink-cli-repo"
ln -s "$KIT_ROOT/bin/substrate" "$T/symlink-bin/substrate"
cd "$T/symlink-cli-repo" || exit 9
git init -q .
git config user.email substrate@localhost
git config user.name substrate
"$T/symlink-bin/substrate" bootstrap --profile base >/dev/null 2>&1 \
    || fail "symlinked CLI did not resolve the source kit"
cmp -s .substrate/VERSION "$KIT_ROOT/VERSION" \
    || fail "symlinked CLI installed a runtime from the wrong kit"

printf 'bootstrap-test: fresh, sync, ownership, force-adopt, symlink-cli, preservation green\n'
