# Substrate Contracts

The interfaces every component implements. Change these deliberately — everything else is replaceable.

## Design rules (inherited from the dotfiles prototype, each bought with a failure)

1. Fail closed: detector exit >=2 = infrastructure failure = red gate. Never `2>/dev/null` a detector. A missing tool on a load-bearing check is fatal; warn-and-skip is legal only where CI is guaranteed to run the check, and missing-in-CI fails.
2. Block-and-report at write time; never silently mutate agent output. Every rejection message says what to do instead.
3. Ratchet, don't absolutize: grandfathered debt lives in the baseline; regressions fail; the writer refuses on a red gate; loosening requires `--accept-regression` and prints the diff.
4. Escape hatches are line-scoped, diff-visible markers (`gate:allow-*`). The `unscanned` ledger has the same reviewed status. No config-wide off switches.
5. Negative tests ship with the gate (`substrate selftest`).
6. Both harnesses or it doesn't ship: Claude Code hooks and the omp extension read the same config.
7. Never write through symlinks; protect governance docs, baselines, and `.substrate/` at the hook layer.
8. No `sed`/`awk`; bash + jq + coreutils. Config is JSON, parsed only with jq (bash) or JSON.parse (Bun) — trivial parsers, no YAML.

## substrate.json (repo root, tracked; created by `substrate init`)

```json
{
  "version": 1,
  "profiles": ["go"],
  "inventory": "auto",
  "unscanned": ["*.md", "*.json", "LICENSE", "docs/**"],
  "protected_paths": ["*.env", "secrets/**"],
  "comment": { "allow_tags": ["SAFETY:", "WHY:", "PERF:", "HACK:"] },
  "budgets": { "max_file_lines": 500 },
  "checks": { "disabled": [] },
  "contracts": [{ "name": "api", "regen": "bun run generate", "paths": ["src/generated"] }],
  "push_gate": true
}
```

- `inventory`: `auto` (jj when `.jj/` exists, else git), `git`, or `jj`. Submodule contents are always excluded.
- `unscanned`: globs for tracked files no profile claims — a reviewed ledger, not a default. A tracked source file matching neither a profile claim nor `unscanned` FAILS the gate (check `05-unclaimed-source`).
- `protected_paths`: repo-specific write-blocks; the core always protects the baseline, `.substrate/`, and symlink writes.
- `contracts`: SSOT drift gates. `45-contract-drift.sh` copies the tracked tree to a scratch dir, runs each `regen` there (the working tree is never mutated), and diffs every `paths` entry — drift is findings, a failing regen is infra-red. `paths` are LITERAL files or directories (not globs); both hooks write-block them ("edit the contract source; the gate regenerates") and fail closed on malformed entries. A missing generator binary (first token of `regen`) skips locally and is fatal under CI, `require_bin_ci`-style. This also makes deterministic code indexes safe to keep (evaluated on Graphify 2026-07): declare the index build as a contract and staleness — the classic objection to every index — becomes a drift-gated invariant with write-blocked output. LLM-built graph layers stay out: measured yield varied 7x across extractor models on the same corpus (a sample, not an index).

## profile.json (`profiles/<name>/profile.json`; repo-local profiles in `<repo>/substrate-profiles/<name>/`)

```json
{
  "name": "go",
  "claims": {
    ".go": { "mode": "ast", "ast_lang": "go", "markers": ["//"] }
  },
  "toolchain": [{ "bin": "golangci-lint", "hint": "https://golangci-lint.run/usage/install" }],
  "ci": ["curl -sSfL https://raw.githubusercontent.com/golangci/golangci-lint/HEAD/install.sh | sh -s -- -b $(go env GOPATH)/bin"],
  "templates": [{ "src": "golangci.yml", "dest": ".golangci.yml" }],
  "checks": ["60-golangci.sh"],
  "slop_fixture": "fixtures/slop.go"
}
```

- `claims` maps each extension to its comment-gate config: `mode` is `ast` (ast-grep grammar exists), `line` (marker-based substring extraction with quote/heredoc/block awareness), or `exempt` (another tool owns the file type — e.g. svelte).
- `markers`: line-comment markers for the classifier's regex alternation (`#`, `//`, `--`). Block pairs: `"block": [["/*", "*/"]]`; `"heredoc": true` enables `<<TAG` body skipping in line mode.
- `ci`: shell lines injected into the CI workflow's toolchain step at init.
- `templates` are copied by `init` only when `dest` is absent — repo edits win forever after.
- `slop_fixtures` are native-language files each containing exactly one slop comment; `selftest` injects every one and requires red at the injected path. Include an extensionless shebang fixture when the profile declares `shebang` mappings. A profile without fixtures cannot pass selftest.
- `shebang` maps interpreter names onto a claim entry (`{"interpreters": ["bash", "sh"], "as": ".sh"}`) so extensionless executables are claimed source, not ledger fodder.
- `check_fixtures` pair a bad file (or directory) with the check that must reject it: `[{"file": "fixtures/bad-vet.go", "fails": "61-go-vet.sh"}]`. `test/matrix.sh` injects each into a scratch repo and requires the gate red with that check named. A profile that ships checks without check_fixtures fails the matrix — checks without an oracle do not ship. Toolchain-absent machines skip the assertion with a printed note; under `CI` the toolchain is mandatory, so the assertion always runs there.

## langmap.json (generated into `.substrate/` by init/update; never hand-edited)

Merged claims of active profiles: `{".go": {"mode": "ast", "ast_lang": "go", "markers": ["//"], "block": [], "profile": "go"}}`. Duplicate claims across active profiles are an init-time error.

## Check contract (`checks.d/NN-name.sh`)

Executable bash. Environment: `REPO_ROOT` (cwd), `SUBSTRATE_DIR`, `CONFIG`, `LANGMAP`, `INVENTORY` (file listing tracked paths), `METRICS` (append-only jsonl), `BASELINE` (read-only path; may not exist yet). Must `source "$SUBSTRATE_DIR/gate-lib.sh"`.

- exit 0 — pass
- exit 1 — findings; the report is stdout, every line actionable (`file:line — problem — fix`)
- exit >=2 — infrastructure failure; the runner fails the gate with "cannot pass blind"

Ratcheted measurements: `metric <name> <value>` (lower is better — the only direction in v1). The RUNNER compares against `baseline.metrics[name]`: regression fails, improvement prints a lock-in hint, `--update-baseline` (refused while red) writes emitted values. Per-file ratchets are just namespaced metrics: `metric "comments:src/x.go" 2`.

Ordering: core checks 05–59, profile checks 60–79, repo-local checks 80–99. `checks.disabled` in substrate.json removes by filename; disabling is diff-visible.

## Baseline (`substrate-baseline.json`, repo root, tracked)

`{"metrics": {"dup_pct": 0.28, "comments:src/x.go": 2}}`. Written only by the runner: refused while any check fails (first creation is allowed on a run whose only complaints are missing-baseline warnings), `--accept-regression` prints the exact diff being relaxed. When the file exists, an absent metric key means zero tolerance.

## Hook contract

- `hooks/protect-paths.sh` — PreToolUse(Write|Edit) stdin JSON; blocks: any symlink write (message names the target), baseline, `.substrate/`, `CLAUDE.md`/governance, `protected_paths` globs. Exit 2 = blocked.
- `hooks/comment-ratchet-posttool.sh` — PostToolUse(Write|Edit); runs the comment checker on the touched file; exit 2 with report when the file exceeds its baseline metric; detector exit >=2 also exits 2 (infra failure must not read as pass).
- `hooks/gate-before-push.sh` — PreToolUse(Bash) matching the repo's push command; runs the gate; exit 2 with report on red.
- `omp/quality.ts` — same three behaviors via ExtensionAPI `tool_call`/`tool_result`, reading `substrate.json` + `langmap.json` directly (Bun `JSON.parse`); subprocesses via `Bun.spawnSync`.

## CLI surface (`bin/substrate`)

- `init [--profile a,b] [--vcs auto|git|jj] [--force]` — vendor core into `.substrate/`, write `substrate.json` (seeded `unscanned`), generate langmap, copy profile templates (absent-only), install checks, wire gate recipe (justfile/Makefile append-or-create), CI workflow, Claude settings merge (single-input `--argjson`, jaq-safe, guarded — a failed merge writes nothing), omp extension copy. Never creates a baseline.
- `gate [...]` — run `.substrate/gate.sh` (flags pass through: `--update-baseline`, `--accept-regression`).
- `doctor` — config validity, langmap freshness (regenerate + compare), toolchain presence per active profile with hints.
- `update [--apply]` — diff vendored `.substrate/` against the kit version; `--apply` re-vendors. Local `substrate.json`, baseline, templates, repo checks are never touched.
- `update --apply` also refreshes the installed omp extension copy (`.omp/extensions/substrate-quality.ts`) — `80-vendor-drift` pairs it in the kit repo.
- `selftest` — sandbox copy of the repo (inventory files only), then: steady must be green (or baseline-pending warns only); per-profile slop fixture injected must go red AND be named in the report; detector tool shimmed to fail must go red with "cannot pass blind"; corrupt baseline must hard-exit. Any deviation = selftest fails.
- `audit [plan.md ...]` — executes plan acceptance oracles (see Plan tracking). Checked `[x]` items must pass (regression = exit 1); `committed` plans must pass everything; pending `[ ]` items on active plans report without failing.

## Versioning

`.substrate/VERSION` is stamped at init/update. `substrate update` refuses when the vendored version is newer than the kit (downgrade needs `--force`).

## Plan tracking (`.pi/plans/*.md`)

The durable home for research, decisions, and acceptance — pipeline attrition (research → plan → tasks → done-claims, each hop lossy) is gated, not hoped away. Adopted from processes that don't lose knowledge: one stateful artifact per initiative (Rust tracking issues, K8s KEPs, Oxide RFDs), machine-gated progression (kepval/PRR-blocking analogs), append-only lifecycle (supersede, never delete), and docs that converge to reality or die in CI (doctest analog: executable acceptance).

- Every plan carries exactly one `state: draft|active|committed|superseded|abandoned` line. Committed = every acceptance item checked; committed with zero items requires an explicit `acceptance: none — <reason>` waiver. Superseded requires a `superseded-by: <where>` pointer and abandoned a `reason:` line — terminal states carry obligations; frozen history is never deleted.
- `## Acceptance` items are `- [ ] <claim> :: <verify-command>` — the claim's oracle, run from the repo root. A checked box is a locked claim.
- `15-tracking.sh` (every gate, fast): state line valid, items well-formed, active plans have oracles, committed plans have no unchecked items.
- `substrate audit` (CI, heavy): runs every oracle; `[x]`-regression or a failing committed plan is red. Green pending items print "check the box".
- Trust model: acceptance verify commands EXECUTE in CI — review plan edits as code, not prose. The consumer CI template scopes the audit step to `push` events so fork PRs cannot run arbitrary plan commands on your runner.
- Convention: commits implementing a plan item reference the plan slug in the message (kernel `Link:` analog — self-contained message first, link for depth).
