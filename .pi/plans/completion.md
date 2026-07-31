# Plan: substrate completion — 100% on all four pillars
state: committed

Supersedes the completion scope of `~/dotfiles/.pi/plans/substrate-kit.md` (kept as historical anchor + audit trail). This file is the tracked, gated artifact of record: `15-tracking.sh` enforces its shape at every gate; `substrate audit` executes every oracle below; CI runs both.

## Research (decisions carried, kernel-style: self-contained here, links for depth)

Failure mode #5 — pipeline attrition: research → plan → tasks → done-claims, each hop lossy. Fixes adopted from processes that demonstrably do not lose knowledge:

1. One stateful artifact per initiative (Rust tracking issues; K8s KEP kep.yaml; Oxide RFD states). Artifact count scales with decisions, not files — the anti-SDD-sprawl stance.
2. Progression machine-gated (kepval presubmit; PRR blocking since k8s 1.21; Rust `#[unstable(issue = "...")]` required and compiled; Ghostty auto-closes PRs lacking an issue).
3. Code→rationale link enforced in the artifact (kernel `Link:` to lore Message-ID; Cloudflare prompt-in-commit; aider mechanical blame stats). Commits self-contained first, links for depth.
4. Append-only lifecycle: supersede, never delete (rustc_feature unstable/accepted/removed registries; lore permanence; RFD abandoned state). "The rest" gets a state, never silence.
5. Docs converge to reality or die in CI (doctests, mdbook test, AST-anchored drift linters). Authored-spec-as-truth rots (Spec Kit #1191 net-new-only; "sea of markdown" critiques).

Mechanism: `## Acceptance` items are `- [ ] claim :: verify-command`. A checked box is a locked claim — audit fails on regression. Committed state requires everything green.

## Acceptance

### Tracking machinery
- [x] maintenance report vendored, scheduled, queue proven :: test -x core/report.sh && grep -q 'schedule:' core/ci/github-report.yml && test/report-e2e.sh
- [x] init hooks merge is idempotent :: test/init-idempotent-test.sh
- [x] harness parity check fires on a stripped mirror :: test/parity-test.sh
- [x] vendor drift check fires on mutation :: test/vendor-drift-test.sh
- [x] tracking check rejects committed-with-open-work plans :: CI=1 test/matrix.sh base 2>&1 | grep -q '15-tracking.sh rejected bad-plan.md'
- [x] audit fails on regressed checked claims :: test/audit-test.sh
- [x] audit wired into CI :: grep -q 'audit' .github/workflows/substrate-gate.yml

### Contracts pillar (complaint #2 — SSOT, drift-gated)
- [x] contract drift check ships with negative oracle :: test/contract-drift-test.sh
- [x] generated paths write-blocked in both harnesses :: grep -q 'contracts' core/hooks/protect-paths.sh && grep -q 'contracts' core/omp/substrate-quality.ts
- [x] contracts schema documented :: grep -q '"contracts"' docs/contracts.md

### Boundaries (L0 as code)
- [x] python boundaries via import-linter with oracle :: CI=1 test/matrix.sh python 2>&1 | grep -q '62-import-linter.sh rejected'
- [x] typescript boundaries via dependency-cruiser with oracle :: CI=1 test/matrix.sh typescript 2>&1 | grep -q '72-depcruise.sh rejected'
- [x] go boundary and banned-construct linters in template with oracle :: grep -q 'depguard' profiles/go/templates/golangci.yml && grep -q 'forbidigo' profiles/go/templates/golangci.yml && CI=1 test/matrix.sh go 2>&1 | grep -q '76-golangci.sh rejected'
- [x] airflow layering contract with oracle :: CI=1 test/matrix.sh airflow 2>&1 | grep -q '62-import-linter.sh rejected'

### Banned constructs (complaint #4 — corrective pointers)
- [x] python constructs pack with oracle :: CI=1 test/matrix.sh python 2>&1 | grep -q '64-constructs.sh rejected'
- [x] typescript constructs pack with oracle :: CI=1 test/matrix.sh typescript 2>&1 | grep -q '74-constructs.sh rejected'

### Profile depth (to P4 spec or explicit deferral below)
- [x] terraform validate check with oracle :: CI=1 test/matrix.sh terraform 2>&1 | grep -q '70-terraform-validate.sh rejected'
- [x] lua stylua check with oracle :: CI=1 test/matrix.sh lua 2>&1 | grep -q '77-stylua.sh rejected'
- [x] cpp clang-tidy check with oracle, compile-db-gated :: grep -q 'compile_commands.json' profiles/cpp/checks.d/72-clang-tidy.sh && CI=1 test/matrix.sh cpp 2>&1 | grep -q '72-clang-tidy.sh rejected'
- [x] python vulture dead-code check with oracle :: CI=1 test/matrix.sh python 2>&1 | grep -q '63-vulture.sh rejected'
- [x] dbt manifest discipline check with oracle :: CI=1 test/matrix.sh dbt 2>&1 | grep -q '66-dbt-manifest.sh rejected'
- [x] svelte enforcing via svelte-check with oracle :: CI=1 test/matrix.sh svelte 2>&1 | grep -q '73-svelte-check.sh rejected'

### P5 process layer
- [x] substrate report emits maintenance queue :: bin/substrate report 2>&1 | grep -qi 'maintenance'
- [x] skills packaged kit-local :: test -f skills/context-pack/SKILL.md && test -f skills/review/SKILL.md
- [x] init installs skills into consumer repos :: S=$PWD/bin/substrate; T=$(mktemp -d) && (cd "$T" && git init -q . && "$S" init --profile shell >/dev/null 2>&1; test -f .claude/skills/context-pack/SKILL.md); rc=$?; rm -rf "$T"; exit $rc
- [x] guides ported kit-generic :: test -f guides/README.md && test -f guides/daily-workflow.md

### Proof on remote
- [x] kit repo has a remote :: git remote get-url origin >/dev/null 2>&1
- [x] Actions CI has a green run :: [ -n "${GH_TOKEN:-}" ] || export GH_TOKEN=$(gh auth token -u secondary-user 2>/dev/null); if [ -z "${GH_TOKEN:-}" ]; then [ -z "${CI:-}" ] || exit 1; exit 0; fi; gh run list --status success --limit 1 --json conclusion --jq '.[0].conclusion' | grep -qx success

## Deferred (each with a reason — a state, not silence)

- eslint (typescript): flat-vs-legacy config ecosystem makes a deterministic zero-config invocation brittle; tsc + dependency-cruiser + constructs pack carry the load. Revisit when a config-independent invocation exists.
- knip (typescript): dead-export ratchet is repo-config-dependent; belongs in `substrate report`, not the gate.
- trivy/checkov (terraform): policy DBs update daily — verdicts drift over time, violating gate determinism. Revisit pinned-DB mode as a report section.
- sqlfluff dbt templater: requires dbt importable inside sqlfluff's env; per-repo venv coupling too heavy for a kit default. dbt parse + manifest checks carry the contract.
- react overlay: no consumer yet; built on adoption (kit rule: no speculative profiles).
