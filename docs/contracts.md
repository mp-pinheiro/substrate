# Substrate Contracts

The interfaces every component implements. Change these deliberately — everything else is replaceable.

## Design rules (inherited from the dotfiles prototype, each bought with a failure)

1. Fail closed: detector exit >=2 = infrastructure failure = red gate. Never `2>/dev/null` a detector. A missing tool on a load-bearing check is fatal; warn-and-skip is legal only where CI is guaranteed to run the check, and missing-in-CI fails.
2. Block-and-report at write time; never silently mutate agent output. Every rejection message says what to do instead.
3. Ratchet, don't absolutize: grandfathered debt lives in the baseline; regressions fail; the writer refuses on a red gate; loosening requires `--accept-regression` and a recorded reason committed to the baseline diff. `ratchet.never_accept` forbids accepting specific metrics outright.
4. Escape hatches are line-scoped, diff-visible markers (`gate:allow-*`). The `unscanned` ledger has the same reviewed status. No config-wide off switches.
5. Negative tests ship with the gate (`substrate selftest`).
6. Both harnesses or it doesn't ship: Claude Code hooks and the omp extension read the same config.
7. Never write through symlinks; protect governance docs, baselines, and `.substrate/` at the hook layer.
8. No `sed`/`awk`; bash + jq + coreutils. Config is JSON, parsed only with jq (bash) or JSON.parse (Bun) — trivial parsers, no YAML.

## substrate.json (repo root, tracked; created by `substrate bootstrap`)

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
  "ratchet": { "never_accept": ["dead_code"] },
  "contracts": [{ "name": "api", "regen": "bun run generate", "paths": ["src/generated"] }]
}
```

- `inventory`: `auto` (jj when `.jj/` exists, else git), `git`, or `jj`. Submodule contents are always excluded.
- `unscanned`: globs for tracked files no profile claims — a reviewed ledger, not a default. A tracked source file matching neither a profile claim nor `unscanned` FAILS the gate (check `05-unclaimed-source`).
- `substrate.json`: human-approved policy configuration; write-time hooks block agent file and shell mutations. Change it only through the guarded maintenance workflow with explicit human direction.
- `ratchet`: opt-in regression policy. `ratchet.never_accept` is an array of metric keys that must never be accepted with `--accept-regression`. Absent key means the empty list — no `die_infra`, unlike `budgets`.
- `contracts`: SSOT drift gates. `45-contract-drift.sh` copies the tracked tree to a scratch dir, runs each `regen` there (the working tree is never mutated), and diffs every `paths` entry — drift is findings, a failing regen is infra-red. `paths` are LITERAL files or directories (not globs); both hooks write-block them ("edit the contract source; the gate regenerates") and fail closed on malformed entries. A missing generator binary (first token of `regen`) skips locally and is fatal under CI, `require_bin_ci`-style. This also makes deterministic code indexes safe to keep (evaluated on Graphify 2026-07): declare the index build as a contract and staleness — the classic objection to every index — becomes a drift-gated invariant with write-blocked output. LLM-built graph layers stay out: measured yield varied 7x across extractor models on the same corpus (a sample, not an index).

## profile.json (`profiles/<name>/profile.json`; repo-local profiles in `<repo>/substrate-profiles/<name>/`)

```json
{
  "name": "go",
  "claims": {
    ".go": { "mode": "ast", "ast_lang": "go", "markers": ["//"] }
  },
  "toolchain": [{ "bin": "golangci-lint", "hint": "https://golangci-lint.run/usage/install" }],
  "ci": [
    "curl -sSfL -o /tmp/install-golangci-lint.sh https://raw.githubusercontent.com/golangci/golangci-lint/c0d3ddc9cf3faa61a4e378e879ece580256d76e5/install.sh",
    "sh /tmp/install-golangci-lint.sh -b $(go env GOPATH)/bin v2.12.2"
  ],
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

Executable bash. Environment: `REPO_ROOT` (cwd), `SUBSTRATE_DIR`, `CONFIG`, `LANGMAP`, `INVENTORY` (file listing tracked paths), `CLAIMS` (0x1F-separated `path·profile·ast_lang·mode·entry` rows — resolved once by the runner; without it `gate-lib.sh` silently falls back to a per-file `jq` path with different scope semantics), `METRICS` (append-only jsonl, a per-check shard), `BASELINE` (read-only path; may not exist yet), `SUBSTRATE_CHECK_NAME` (basename including `.sh`). The runner passes its own environment through unmodified — `CI` in particular is ambient and decides whether `require_bin_ci` dies or skips. Must `source "$SUBSTRATE_DIR/gate-lib.sh"`.

Runner inputs (set by the caller, not by a check): `SUBSTRATE_FILE_LIST` scopes the inventory to a file of paths, used verbatim; `SUBSTRATE_GATE_JOBS` caps concurrency (default `nproc`) and, because reporting lags submission, moves where disabled-check warnings appear in stdout; `SUBSTRATE_CLAIMS_OUT` publishes the resolved CLAIMS table for byte-comparison.

- exit 0 — pass
- exit 1 — findings; the report is stdout, every line actionable (`file:line — problem — fix`)
- exit >=2 — infrastructure failure; the runner fails the gate with "cannot pass blind"

Ratcheted measurements: `metric <name> <value>` (lower is better) and `metric_hi <name> <value>` (higher is better — coverage, type-coverage). The RUNNER compares against `baseline.metrics[name]` using the direction in `baseline.direction[name]` (absent = lower): regression fails, improvement prints a lock-in hint, `--update-baseline` (refused while red) writes emitted values, `--tighten` (used by every checkpoint) lowers/raises existing ceilings component-wise and handles orphaned keys by direction — a lower-is-better orphan is pruned (absence already means zero tolerance, so pruning tightens), a higher-is-better orphan keeps its ceiling AND its direction (absence would mean no floor at all, and losing the direction would re-read the metric as lower-is-better on the next run). Raising a ceiling requires `--accept-regression[=key1,key2]` plus a mandatory `--reason=<text>` (≥20 chars, no shell metacharacters) committed to the `accepted` record in the baseline. `ratchet.never_accept` in `substrate.json` lists metrics that must never be accepted. Regression lines show budget headroom when a `budgets` hard cap exists for the metric: `max_file_lines: 418 (best 413, hard cap 500 — 82 under cap)`.

Per-path profile scoping: `substrate.json`'s `scopes` map restricts which profiles are active per path prefix. A file under `app/` is only claimed if its profile is in `scopes["app/"].profiles`. Files outside all scopes are unaffected. Scope-excluded files are not flagged by `05-unclaimed-source.sh`.

Ordering: core checks 05–59, profile checks 60–79, repo-local checks 80–99. `checks.disabled` in substrate.json removes by filename; `checks.config` tunes execution per check; `scopes` restricts profile claims per path. All are diff-visible.

## Baseline (`substrate-baseline.json`, repo root, tracked)

`{"metrics": {"dup_pct": 0.28, "comments:src/x.go": 2}, "direction": {"coverage": "hi"}, "accepted": {"max_file_lines": {"from": 413, "to": 418, "at": "2026-08-07", "reason": "file grew because..."}}}`. The checkpoint transaction lowers/raises existing ceilings component-wise only after a green run (pruning orphaned lower-is-better keys, retaining orphaned higher-is-better floors with their direction, and reporting every prune), stages the new JSON beside the original, and atomically replaces it before committing. Initial debt adoption remains explicit; `--accept-regression[=key1,key2]` paired with `--reason=<text>` is the only loosening path and prints the exact diff. The `accepted` record's `from` is sticky (first-accepted floor) and auto-prunes when the metric returns to or past its `from`; it is omitted entirely when empty. When the file exists, an absent lower-is-better key means zero tolerance; a higher-is-better metric has no floor without a recorded ceiling, which is why its ceiling survives an idle run.

- `hooks/protect-paths.sh` — PreToolUse(Write|Edit) stdin JSON; blocks: any symlink write (message names the target), baseline, `.substrate/`, `CLAUDE.md`/governance, `protected_paths` globs. Exit 2 = blocked.
- `hooks/changed-files-scan.sh` — PostToolUse(Bash|Write|Edit|MultiEdit|NotebookEdit|Task); scans every changed path in the working tree (jj diff or git status), not the tool's declared target, so bash/eval writes are covered; runs the comment ratchet per changed scannable file (pass-only memo in `$TMPDIR`) and flags `protected_paths` writes the write-time hook could not intercept. Report on stderr, exit 2 = blocking feedback.
- `hooks/gate-before-push.sh`, the Git pre-push hook, and the `jj push` alias call the shared receipt-aware push guard. It accepts only a green receipt whose revision, tracked tree, refs, config inputs, vendored engine/checks, executable toolchain, bounded environment, and declared external SDK fingerprint still match; otherwise it reruns the gate. Arbitrary contract generators and dirty trees are deliberately non-reusable. Push remains an explicit user action and has no opt-out.
- `core/omp/substrate-quality.ts` plus `core/omp/substrate-quality/*.ts` — the executable omp enforcement layer and private runtime modules. The entrypoint's `before_agent_start` handler injects concise gate policy and re-baselines stale ownership state; `tool_call` blocks protected writes, direct commits, and red pushes; `tool_result` scans mutations, including write-tier LSP actions, while proven read-only actions and non-filesystem URI targets (`xd://`, `memory://`, `mcp://`) skip tracking. Ownership tracking never bricks a session: external drift re-baselines at the next clean tool boundary, disowns externally-changed paths, and records a drift notice; "pre-existing" always means currently pending and not owned. The fingerprint-verified ownership ledger persists per repo root under `~/.omp/run/substrate-quality/` and rehydrates across process restarts; the global runtime file carries install identity only. Every target resolves its own repo, including cross-repo and not-yet-created parent paths; symlink ancestors cannot escape that repo. Runtime identity hashes the entrypoint and every private module in a fixed order.
- `install_user_harness` — installs the user-scoped omp entrypoint and private module directory, Claude launcher, and kit-owned agents/skills into `~/.omp/agent` and `~/.claude`; it never creates or changes `~/.omp/profiles/*` and refuses any destination that crosses a symlink.
- Agents and skills are optional helpers, not enforcement. Their ownership is explicit: a same-name destination without `.substrate-managed.json` is repo/user-owned and remains untouched. A valid `{"managed_by":"substrate"}` marker grants full ownership of that asset root: synchronization replaces its complete contents, and a marked asset removed from the kit is removed from consumers. Invalid or symlinked markers fail closed. A repo-local asset-root symlink is accepted only when its canonical target remains inside the repository; writes use that canonical path. User-level roots never traverse symlinks.

## Repository maintenance transaction

`bootstrap`, `init`, and `update --apply` use the same repository transaction. The transaction takes a revision and dirty-tree snapshot, builds a write manifest from the selected operation and profiles, renders a scratch clone, and runs the candidate's vendored gate before touching the working tree. The renderer must stay inside the declared manifest.

Each changed top-level unit records its preimage and desired hash. Apply uses compare-and-swap checks, refuses dirty managed overlap unless a prior receipt or a checked ownership marker authorizes it, and verifies that the revision and unrelated dirty-work fingerprint did not change during rendering. A run without `--checkpoint` may seed repo-owned merge/preserve inputs into the candidate; they are included in preimage checks and the receipt but remain uncommitted. Checkpoint mode refuses those inputs instead of absorbing them. Unrelated dirty paths are preserved. A repository-local lock rejects concurrent maintenance.

With `--checkpoint`, a green candidate tightens existing baseline ceilings and commits exactly the changed managed units through Git's temporary index or a path-scoped jj commit. Initial debt requires `--accept-baseline`; that flag never accepts regression against an existing baseline. The transaction writes a receipt to the repository's common Git metadata before apply. Prepared, applying, applied, and incomplete checkpoint receipts retain the candidate and can resume after interruption. The final receipt records the source and destination revisions, exact changed paths, commit, gate hash, preserved-dirty fingerprint, and `noPush: true`.

Repository runtime wiring runs after the repository commit. User-scoped harness synchronization runs last under its own lock and receipt; `--repo-only` skips it. A failure in either external phase leaves the repository commit intact and a rerun repairs only the unfinished phase. Maintenance never invokes a push.

## CLI surface (`bin/substrate`)

- `bootstrap [--profile a,b] [--vcs auto|git|jj] [--force] [--from-worktree] [maintenance flags]` — the canonical installer and synchronizer. A new repo requires profiles; later runs read them from `substrate.json`. It re-vendors `.substrate/`, re-renders workflows marked `# substrate-managed`, merges individual hook commands without dropping foreign commands from mixed groups, refreshes harness and VCS wiring, and synchronizes kit-owned agents and skills into both Claude and omp. It preserves config templates, repo-owned LSP settings, unmarked same-name assets, and local checks. An unmarked workflow is adopted only when it exactly matches generated output or `--force` is explicit; `# substrate-repo-owned` preserves a custom workflow.
- `init --profile a,b [--vcs auto|git|jj] [--force] [--from-worktree] [maintenance flags]` — first-run-compatible entry point for the same transaction.
- Maintenance flags: `--checkpoint` creates the local commit; `--message <message>` overrides its Conventional Commit message; `--accept-baseline` explicitly adopts initial debt; `--repo-only` skips user-harness synchronization; `--json` prints the receipt; `--from-worktree` vendors from the kit worktree even when it is dirty or unpushed. Symlink escapes, non-regular destinations, manifest escapes, ownership conflicts, and unchained Git hooks fail the transaction.
- `gate [...]` — run `.substrate/gate.sh`; `gate --deep [--no-cache]` additionally runs the cached full-history secret scan.
- `restructure --op split|describe|squash --revision <rev> --message <m> [--message2 <m>] [--into <rev>] [--path <p> ...] (--session <id> | --allow-change <id> ...)` — reshape agent session-authored jj commits behind the same governance: targets must be on the session allow-list (checkpoint receipts seed it), messages follow Conventional Commits, one atomic jj operation executes with rollback via `jj op restore` on conflicts, pending-path changes, or tree changes, and a receipt lands in repository metadata. The omp `substrate_restructure` tool and the Claude session-bound CLI are the only sanctioned entry points; direct `jj describe/squash` stays blocked.
- `checkpoint --message <message> [--session <id> | --path <path> ...] [--accept-regression=<metric>[,<metric>] --reason <text>]` — verify ownership, run the gate, tighten the baseline, commit locally, and record a receipt. It never pushes. Supplied paths must be pending; when unowned pending work remains, the transaction gates the exact commit tree (base revision plus owned paths) in an isolated candidate, commits only the owned paths, leaves the remainder in place and surfaces it, and writes a non-reusable receipt. Only a checkpoint that leaves the working copy clean re-verifies in place and records a reusable exact-state receipt. On session stop both harnesses attempt this checkpoint automatically for owned green work instead of only nagging. `--accept-regression` requires `--reason <text>`; the justification is committed to substrate-baseline.json.
- `doctor` — config validity, langmap freshness (regenerate + compare), installed/loaded harness identity, and toolchain presence per active profile with hints.
- `baseline [--update|--accept-regression[=key1,key2] --reason <text>]` — explicitly establish initial debt or accept a reviewed regression (optionally limited to specific metric keys). Accepting requires a mandatory reason.
- `update [--apply] [--force] [--from-worktree] [maintenance flags]` — without `--apply`, inspect vendored engine drift. With `--apply`, run the repository transaction for the engine, then refresh repository runtime and the user harness.
- `selftest` — sandbox copy of the repo (inventory files only), then: steady must be green (or baseline-pending warns only); per-profile slop fixture injected must go red AND be named in the report; detector tool shimmed to fail must go red with "cannot pass blind"; corrupt baseline must hard-exit. Any deviation = selftest fails.
- `audit [plan.md ...]` — executes plan acceptance oracles (see Plan tracking). Checked `[x]` items must pass (regression = exit 1); `committed` plans must pass everything; pending `[ ]` items on active plans report without failing.

- `report [--write|--refresh]` — advisory cleanup output. Lists duplicate-code candidates, possible dead code, baseline limits, and raised ceilings with ages and deltas. Harness session start refreshes ignored local state when due; scheduled CI owns the durable issue. Report age or generation never changes the code-gate verdict.

`.substrate/VERSION` is stamped by bootstrap/init/update. All three mutation paths refuse when the vendored version is newer than the kit; an explicit `--force` is required to downgrade. Vendoring also refuses when the kit checkout is dirty in `core/ profiles/ skills/ agents/ VERSION engine.json` or its revision is not contained in `origin/main` (or `master`); the kit vendoring into itself is exempt. `.substrate/vendor.json` records `{kitRevision, source, version}` for the vendored copy.

## Plan tracking (`.pi/plans/*.md`)

The durable home for research, decisions, and acceptance — pipeline attrition (research → plan → tasks → done-claims, each hop lossy) is gated, not hoped away. Adopted from processes that don't lose knowledge: one stateful artifact per initiative (Rust tracking issues, K8s KEPs, Oxide RFDs), machine-gated progression (kepval/PRR-blocking analogs), append-only lifecycle (supersede, never delete), and docs that converge to reality or die in CI (doctest analog: executable acceptance).

- Every plan carries exactly one `state: draft|active|committed|superseded|abandoned` line. Committed = every acceptance item checked; committed with zero items requires an explicit `acceptance: none — <reason>` waiver. Superseded requires a `superseded-by: <where>` pointer and abandoned a `reason:` line — terminal states carry obligations; frozen history is never deleted.
- `## Acceptance` items are `- [ ] <claim> :: <verify-command>` — the claim's oracle, run from the repo root. A checked box is a locked claim.
- `15-tracking.sh` (every gate, fast): state line valid, items well-formed, active plans have oracles, committed plans have no unchecked items.
- `substrate audit` (CI, heavy): runs every oracle; `[x]`-regression or a failing committed plan is red. Green pending items print "check the box".
- Trust model: acceptance verify commands EXECUTE in CI — review plan edits as code, not prose. The consumer CI template scopes the audit step to `push` events so fork PRs cannot run arbitrary plan commands on your runner.
- Convention: commits implementing a plan item reference the plan slug in the message (kernel `Link:` analog — self-contained message first, link for depth).
