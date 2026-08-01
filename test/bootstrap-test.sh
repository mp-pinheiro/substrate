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
printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash repo-hook.sh"}]}]}}\n' > .claude/settings.json
chmod 444 .claude/settings.json
mkdir -p .claude/skills/context-pack .omp/agents
: > .claude/agents
printf 'repo-owned skill\n' > .claude/skills/context-pack/SKILL.md
printf 'repo-owned agent\n' > .omp/agents/enemy.md

"$KIT_ROOT/bin/substrate" bootstrap --profile shell >/dev/null 2>&1 \
    || fail "fresh bootstrap failed"
[ -x .substrate/gate.sh ] || fail "gate was not vendored"
grep -q 'repo-hook.sh' .claude/settings.json || fail "repo hook was dropped"
grep -qx '# substrate-managed' .github/workflows/substrate-gate.yml \
    || fail "gate workflow is not marked as managed"
managed_matches .github/workflows/substrate-report.yml "$KIT_ROOT/core/ci/github-report.yml" \
    || fail "report workflow does not match its source"
grep -q 'shellcheck zsh' .github/workflows/substrate-gate.yml \
    || fail "shell profile toolchain missing from gate workflow"
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

config_before=$(sha256sum substrate.json)
printf '{"metrics":{"sentinel":1}}\n' > substrate-baseline.json
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

"$KIT_ROOT/bin/substrate" bootstrap >/dev/null 2>&1 \
    || fail "existing-repo synchronization failed"
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
grep -q '"sentinel":1' substrate-baseline.json \
    || fail "bootstrap changed the baseline"
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
[ ! -e .omp/skills/review/.substrate-managed ] \
    || fail "legacy skill marker survived migration"
[ ! -e .claude/agents/explorer.md.substrate-managed ] \
    || fail "legacy agent marker survived migration"
grep -q '^repo-owned skill$' .claude/skills/context-pack/SKILL.md \
    || fail "repo-owned skill changed during synchronization"
grep -q '^repo-owned agent$' .omp/agents/enemy.md \
    || fail "repo-owned agent changed during synchronization"

printf 'repo-owned workflow\n' > .github/workflows/substrate-report.yml
if "$KIT_ROOT/bin/substrate" bootstrap > bootstrap.out 2>&1; then
    fail "bootstrap adopted an unmarked workflow without --force"
fi
grep -q 'not substrate-managed' bootstrap.out \
    || fail "unmanaged workflow refusal was not actionable"
grep -q '^repo-owned workflow$' .github/workflows/substrate-report.yml \
    || fail "unmanaged workflow was modified"
"$KIT_ROOT/bin/substrate" bootstrap --force >/dev/null 2>&1 \
    || fail "forced workflow adoption failed"
managed_matches .github/workflows/substrate-report.yml "$KIT_ROOT/core/ci/github-report.yml" \
    || fail "forced workflow adoption did not synchronize"
printf '# substrate-repo-owned\nname: custom-workflow\n' > .github/workflows/substrate-report.yml
"$KIT_ROOT/bin/substrate" bootstrap >/dev/null 2>&1 \
    || fail "explicitly repo-owned workflow made bootstrap incomplete"
grep -q '^name: custom-workflow$' .github/workflows/substrate-report.yml \
    || fail "explicitly repo-owned workflow was modified"

if "$KIT_ROOT/bin/substrate" bootstrap --profile lua > bootstrap.out 2>&1; then
    fail "bootstrap accepted profiles that disagree with substrate.json"
fi
grep -q 'requested profiles differ' bootstrap.out \
    || fail "profile mismatch refusal was not actionable"

printf 'bootstrap-test: fresh, sync, ownership, force-adopt, preservation green\n'
