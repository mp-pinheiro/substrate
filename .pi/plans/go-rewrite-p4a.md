# Plan: Go engine rewrite — P4a (checkpoint + restructure in Go)
state: superseded
issue: https://github.com/mp-pinheiro/substrate/issues/12
parent: .pi/plans/go-rewrite.md
superseded-by: .pi/plans/go-rewrite-p4b.md

Port the checkpoint and restructure transactions from bash to Go behind capability-probe delegation seams (same pattern as P3's gate delegation). The maintenance subsystem is deferred to P4b — it builds on the candidate-tree infrastructure established here. jj/git stay subprocesses; the P2 receipt authority and P1 ledger remain the Go-side state.

Read first: `.pi/plans/go-rewrite.md` (12 resolutions, shared-artifact compat table, amendments A1–A40), then `.pi/plans/go-rewrite-p3.md` (bindings C1–C13 — the delegation seam pattern is reused). Both are self-contained; no chat context required.

## Context

Issue #12's migration plan has P0–P3 landed (hooks, receipts, gate runner all Go-owned behind shims). P4 is "transactions in Go" — checkpoint, restructure, and maintenance. This plan covers P4a: checkpoint (~258 LOC bash, `core/checkpoint.sh`) and restructure (~230 LOC bash, `core/restructure.sh`), the two self-contained transaction state machines. P4b covers maintenance (~930 LOC across 6 bash files) and the A17 maintenance-lib engine verbs; it depends on the candidate-tree infrastructure P4a establishes.

Motivation: checkpoint is `substrate_checkpoint` — the agent's own commit tool, called on every gated checkpoint. It pays the ~25-jj-invocation receipt overhead (P2 already moved receipt hashing to Go) plus the candidate-tree creation (git archive + tar + cp + git init/add/commit + gate inside candidate) entirely in bash subprocesses. Restructure is the agent's jj-commit-reshaping tool. Both are on the hot path of every agent session.

End state: `internal/transaction` owns checkpoint and restructure. `core/checkpoint.sh` and `core/restructure.sh` gain delegation probes (same pattern as `core/gate.sh:63-75`). The bash implementations stay as `_v1` rollback legs until P5 deletes them. `SUBSTRATE_ENGINE=go|auto` delegates to `substrate-engine checkpoint` / `substrate-engine restructure`; `SUBSTRATE_ENGINE=bash` forces the bash leg. A/B oracles prove byte-identical stdout/stderr/exit/state on both legs.

## Approach

### Seam shape (D1 — same pattern as P3 C1)

`core/checkpoint.sh` and `core/restructure.sh` each gain a capability-probe delegation block at the top, between arg parsing and the existing bash body. The pattern mirrors `core/gate.sh:55-80`:

```
ENGINE_MODE=${SUBSTRATE_ENGINE:-auto}
if substrate_engine_supports checkpoint; then
    if [ "$ENGINE_MODE" = "go" ] || [ "$ENGINE_MODE" = "auto" ]; then
        substrate-engine checkpoint "$@"
        rc=$?
        [ "$rc" -eq 2 ] && die 'engine checkpoint returned unknown-verb after capability probe'
        exit "$rc"
    fi
elif [ "$ENGINE_MODE" = "go" ]; then
    die 'SUBSTRATE_ENGINE=go but no engine binary found or capability probe failed'
fi
```

The engine runs as a **foreground child with inherited stdio** — never `exec`, never `$(...)` capture (same rationale as P3 C1: the EXIT trap never fires under `exec`; live streams matter). The engine handler for `checkpoint` and `restructure` **never returns 2** (reserved for unknown-verb default); its own preflight refusal is sentinel rc **12** (verified free). The wrapper remaps 12→2 if needed.

The `capabilities` verb gains `checkpoint` and `restructure` entries in `cmd/substrate-engine/main.go`.

### Shared candidate-tree infrastructure (D2)

New package `internal/transaction` with:

- `internal/transaction/common.go` — metadata dir resolution (reuses `internal/vcs`), VCS detection (jj vs git via `vcs.DetectVCS`), mkdir-based lock acquisition/cleanup (same lock paths as bash: `$metadata_dir/substrate-checkpoint.lock`, `$metadata_dir/substrate-restructure.lock`), path normalization (reject absolute/../ paths), `LC_ALL=C sort -u` for path lists via `internal/xshell`.
- `internal/transaction/candidate.go` — `GitArchive` (run `git archive --format=tar --output=<archive> <base>`, then `tar -xf` into candidate dir), `OverlayFiles` (cp -P --preserve=mode for each owned path from worktree into candidate, creating parent dirs as needed, rm -f for deleted paths), `SeedRepo` (git init, config, add -A, commit) in the candidate, `GateInCandidate` (run `.substrate/gate.sh --tighten` or `.substrate/gate.sh` with the inherited environment, unset SUBSTRATE_FILE_LIST), `CopyBaseline` (copy candidate's baseline back to worktree preserving mode).

Reuse: `internal/vcs.Revision()` for `current_gate_revision`, `internal/vcs.Summary()` for jj vs git detection, `internal/xshell.Run()` for all subprocess invocations. No existing Go equivalent for the candidate-tree pattern — it's new code.

Checkpoint's path-scoped mode and P4b's maintenance candidate share `internal/transaction/candidate.go`. This is why P4a precedes P4b.

### Checkpoint port (D3)

`internal/transaction/checkpoint.go` — verb `checkpoint`. Port `core/checkpoint.sh:1-268` step by step:

1. **Arg parsing**: `--message`, `--session`, `--path` (repeatable), `--accept-regression=<csv>`, `--reason=<text>`, `--json`. Same validation: Conventional Commits regex (`^(feat|fix|...)(\([^)]+\))?!?: [^[:space:]]`); `--accept-regression` requires `--reason`; `--reason` requires `--accept-regression`.
2. **Preflight**: vendored runtime exists (`.substrate/gate.sh` + `.substrate/hooks/protect-paths.sh`); baseline file exists.
3. **VCS detection**: jj (if `.jj` present and `jj` on PATH) vs git. Resolve metadata dir (`maintenance_metadata_dir` pattern: `git rev-parse --git-common-dir` or `.jj`).
4. **Lock**: `mkdir "$metadata_dir/substrate-checkpoint.lock"`. Trap cleanup (rmdir).
5. **Ownership verification**: If `--session`, call the Go lifecycle engine's `Verify` to get owned paths (reuse `internal/lifecycle`). Otherwise, paths come from `--path` args — validate each is actually pending (changed in working copy).
6. **Path normalization**: reject absolute/..//, dedup, `LC_ALL=C sort -u`. Compare requested paths against current dirty paths via `comm -23` equivalent (set difference). If any requested path is not pending → fail. Compute leftover (paths pending but not requested) via `comm -13` equivalent.
7. **Full-repo mode** (empty leftover): run gate `--tighten` with accept flags. If gate fails → fail. Run gate again (post-commit verify, only in this mode). Commit owned paths (+baseline if changed) via jj or git. Write receipt (delegate to `internal/receipt`). Call lifecycle `Complete` if `--session`. Verify post-commit pending paths match expected leftover.
8. **Path-scoped mode** (non-empty leftover): reject if baseline is in leftover. Build candidate tree from base revision via `git archive` + owned file overlays. Seed candidate git repo. Run gate `--tighten` in candidate (unset SUBSTRATE_FILE_LIST). Copy candidate baseline back to worktree if changed. Commit only owned paths (+baseline if changed) via jj or git. Write receipt. Call lifecycle `Complete`. Verify post-commit dirty paths haven't changed.
9. **Output**: gate output to stdout, commit output to stdout, `--json` prints receipt JSON; otherwise `checkpoint complete: <sha> (<message>)`. Leftover paths to stderr.
10. **Cleanup trap**: remove temp files, rmdir lock. Same semantics as bash.

**Commit logic** — jj mode: `jj commit --message "$message" -- <paths...>`, then `jj log -r @- --no-graph -T commit_id` for the commit hash. Git mode: `git add -- <paths...>`, then `git commit --only -m "$message" -- <paths...>`, then `git rev-parse HEAD` for the commit hash. On git commit failure: `git reset --quiet -- <paths...>` and fail. Exact argv preserved.

**Receipt**: `write_gate_receipt checkpoint "$commit" "$vcs" "$session" "$accept_csv"` — already delegated to the Go engine via `core/receipt-lib.sh`'s P2 seam. The Go checkpoint calls `internal/receipt.WriteCheckpointReceipt()` directly; the bash shim delegates to `substrate-engine receipt write` via the existing seam. No new receipt work needed.

**A31 scan** (W1): The P1 `comm` locale fix is already landed (LC_ALL=C on the comm calls). No known A31 exceptions in checkpoint — W1 audits for new ones. Known candidate: the path-scoped mode's `git cat-file -e "$base^{commit}"` — if `base` is empty, this could fail silently. Verify both legs handle the empty-base case identically.

### Restructure port (D4)

`internal/transaction/restructure.go` — verb `restructure`. Port `core/restructure.sh:1-234`:

1. **Arg parsing**: `--op` (split/describe/squash), `--revision`, `--into`, `--message`, `--message2`, `--path` (repeatable for split), `--session`, `--allow-change` (repeatable), `--json`.
2. **jj-only requirement**: requires `.jj` + `jj` on PATH. No git fallback.
3. **Conventional Commits**: validate `--message` and `--message2` against the same regex as checkpoint.
4. **Revision resolution**: `resolve_change` — `jj log --no-graph -T 'change_id ++ "\n"' -r "$revision"` to get the change_id, require exactly one match. Same for `--into` if provided (squash).
5. **Session authorization**: if `--session` provided, read the session ledger (`internal/lifecycle`) for `.sessionChanges` to build the allow list. If `--allow-change` provided, those are the allow list. At least one allowed change is required.
6. **Path normalization**: same safe-path validation as checkpoint (reject absolute/..//, etc.).
7. **Lock**: `mkdir "$metadata_dir/substrate-restructure.lock"`.
8. **State capture**: `pending_before` = `jj diff --name-only` sorted with `LC_ALL=C`. `tip_before` = `jj log -r @ --no-graph -T commit_id`. `op_before` = `jj op log -n 1 --no-graph -T 'id.short(64)'`.
9. **Rollback**: `jj op restore "$op_before"` — called on any failure.
10. **Execute operation**:
    - split: `jj split --revision "$target_change" --message "$message" -- "${paths[@]}"` → captures new change_ids from `jj log`. If `--message2` provided, `jj describe --revision "$remainder" --message "$message2"`.
    - describe: `jj describe --revision "$target_change" --message "$message"`.
    - squash: `jj squash --revision "$target_change" --into "$into_change" --message "$message"`.
11. **Post-op validation**: no conflicts (empty `jj log -r 'conflicts()'`), pending paths unchanged, working-copy tree unchanged (`jj diff --from tip_before --to @ --name-only` empty).
12. **Receipt**: `jq -cn` construction of the restructure receipt JSON (same schema as bash). Write to `$metadata_dir/substrate/restructure-receipt.json` (atomic mktemp+chmod 600+mv).
13. **Session update**: if `--session`, update `.sessionChanges` in the session ledger — add new change_ids from split, or update the completedCommit reference.
14. **Output**: `--json` prints receipt; otherwise `restructured: <change> (<op>)`.

**JJ invocation inventory** — exact argv preserved: `jj log` (resolve revisions), `jj diff --name-only`, `jj op log`, `jj split`, `jj describe`, `jj squash`, `jj op restore`, `jj log -r conflicts()`. All via `internal/xshell`.

**A31 scan** (W1): The `resolve_change` function uses `jj log -r "$revision"` which could fail if the revision doesn't resolve. This is a fail-closed path (error → exit 2). No known data-destroying bugs in restructure.

### Thrust of the port

All subprocess invocations use `internal/xshell.Run()` with `LC_ALL=C` for any sort/comm operations. JSON construction uses `internal/canonjson` for byte-frozen receipt builders. The lock pattern (mkdir + trap rmdir) is reproduced in Go via an `os.Mkdir` + `defer os.Remove` pattern in `common.go`.

No new Go internal packages are needed beyond `internal/transaction`. The existing packages (`vcs`, `xshell`, `receipt`, `lifecycle`, `config`, `canonjson`, `logx`, `gate`) are reused. `internal/transaction/candidate.go` is the only code shared with P4b.

## Work items (ordered; repo green between each)

### W0 — plan only

Land this file. Add `checkpoint` and `restructure` to the master plan's P4 section as a reference. Update `go-rewrite.md` P4 to note the P4a/P4b split.

Merge gate: `bash .substrate/gate.sh` green (text-only change).

### W1 — oracle freeze + A31 scan (bash-only)

1. Run all three existing test suites on the **bash leg only** to confirm green: `test/checkpoint-test.sh`, `test/restructure-test.sh`, `test/maintenance-test.sh`.
2. Audit checkpoint.sh and restructure.sh for A31-class bugs (data-destroying or guard-disabling). If any are found, fix BOTH legs in the same batch and add an oracle (RED-first, then GREEN). Each A31 exception is its own commit.
3. Add `SUBSTRATE_ENGINE` export to the three test suites in the same pattern as A33 (P3): `test/lib/golden-fixture.sh` already pins `SUBSTRATE_ENGINE="${GOLDEN_ENGINE:-bash}"`; P4a does the same for `test/checkpoint-test.sh` and `test/restructure-test.sh` — add an outer `bash|go` loop so both legs are tested, or add a new dual-leg wrapper.
4. Create new oracle suites:
   - `test/transaction-ab-test.sh` — A/B diff harness for checkpoint and restructure on both legs. Same pattern as `test/gate-ab-test.sh` (durations masked, order preserved). Fixture matrix: full-repo git checkpoint, full-repo jj checkpoint, path-scoped git checkpoint, path-scoped jj checkpoint (with leftover), checkpoint with accept-regression, checkpoint with session, restructure split, restructure describe, restructure squash, restructure with session, restructure into non-authored commit (rejection), checkpoint of non-pending path (rejection), checkpoint of governed path (rejection).
   - `test/transaction-rollback-test.sh` — exercises `SUBSTRATE_ENGINE=bash|go|auto` and `SUBSTRATE_ENGINE_SKIP` for the checkpoint and restructure verbs (same pattern as `test/engine-rollback-test.sh` and `test/gate-rollback-test.sh`).

Merge gate: existing three suites green on bash leg; new suites demonstrate the Go leg is RED (not yet implemented) or skipped; bash leg of new suites green.

### W2 — shared infrastructure + checkpoint port

1. `internal/transaction/common.go`: metadata dir, VCS detection, lock, path normalization, sorted path lists. Smoke-tested against this repo's real VCS state.
2. `internal/transaction/candidate.go`: git archive → tar → overlay → seed → gate-in-candidate → copy-baseline. Smoke-tested with a scratch fixture.
3. `internal/transaction/checkpoint.go`: full port of `core/checkpoint.sh` per D3. New verb `checkpoint` in `cmd/substrate-engine/main.go` with the 12→2 remap.
4. `core/checkpoint.sh`: add delegation probe (D1 pattern) after arg parsing, before the bash body. The bash body stays UNCHANGED as the `_v1` rollback leg.
5. Re-vendor `.substrate/checkpoint.sh` via `bin/substrate update --apply --force --checkpoint --message 'feat(engine): checkpoint delegation seam'`.

Merge gate: `test/checkpoint-test.sh` dual-leg green (byte-identical stdout/stderr/exit); `test/transaction-ab-test.sh` checkpoint scenarios green on both legs; `test/transaction-rollback-test.sh` checkpoint rollout green.

### W3 — restructure port

1. `internal/transaction/restructure.go`: full port of `core/restructure.sh` per D4. New verb `restructure` in `cmd/substrate-engine/main.go`.
2. `core/restructure.sh`: add delegation probe (D1 pattern). Bash body unchanged.
3. Re-vendor `.substrate/restructure.sh` via the sanctioned update path.

Merge gate: `test/restructure-test.sh` dual-leg green; `test/transaction-ab-test.sh` restructure scenarios green on both legs; `test/transaction-rollback-test.sh` restructure rollout green.

### W4 — CI + integration + parent plan update

1. Add `transaction-parity` CI job in `.github/workflows/substrate-gate.yml` (same pattern as the P3 `gate-parity` job): both legs, both must exit 0. Provisions via `test/ci-toolchain.sh --active`.
2. Capabilities list in `cmd/substrate-engine/main.go` updated: `checkpoint` and `restructure` added.
3. `go test ./internal/transaction/...` for any state-machine transition tables (under the A5 narrow waiver).
4. Full serial battery on both forced legs (`just battery`): the exit-criteria run. **Do not repeat** — the per-item merge gates already proved the transactions.
5. `substrate verify` green after an omp restart (C13 probes unchanged — checkpoint/restructure don't touch `policy.ts` or `verify.sh` probes).
6. Update `.pi/plans/go-rewrite.md` P4 section: note P4a committed, P4b draft. Flip parent plan's P4 to split notation.

## Critical files & anchors

- `core/checkpoint.sh` — the ~258-line bash checkpoint; the delegation probe inserts after the arg loop (~line 43) and before the gate-vendoring check (~line 55). Line numbers are hints; re-read before editing.
- `core/restructure.sh` — the ~230-line jj restructure; delegation probe after arg parsing (~line 39).
- `core/gate.sh:55-80` — the P3 delegation seam pattern to copy (capability probe + foreground child + mode check + 12→2 remap).
- `core/engine-shim.sh` — `substrate_engine_supports()` helper used by the probes.
- `internal/receipt/dispatch.go` — the P2 receipt dispatch; checkpoint calls `receipt.WriteCheckpointReceipt()` directly, no new receipt verbs needed.
- `internal/lifecycle/engine.go` — the P1 lifecycle engine; checkpoint calls `Verify` for `--session` ownership and `Complete` post-commit.
- `internal/vcs/repo.go` / `internal/vcs/revision.go` — VCS detection and revision query, reused by checkpoint.
- `internal/xshell/run.go` — subprocess execution wrapper, used for all jj/git/tar invocations.
- `cmd/substrate-engine/main.go` — the switch dispatch; add `case "checkpoint"` and `case "restructure"` with the 12→2 remap, and update the `capabilities` list.

## Verification

### End-to-end proof

Each merge gate is the proof — they are not abstractions:

1. **Checkpoint dual-leg**: `test/checkpoint-test.sh` — runs real git and jj repositories through the checkpoint transaction (accept-regression with reason, bare accept-regression rejection, path-scoped mode with leftover, governed-baseline rejection, jj checkpoint). Run with `SUBSTRATE_ENGINE=go SUBSTRATE_ENGINE_BIN=<built binary>` and `SUBSTRATE_ENGINE=bash`; assert byte-identical stdout/stderr/exit. None of these are mocked.

2. **Restructure dual-leg**: `test/restructure-test.sh` — runs a real jj repo through split/describe/squash, session integration, omp tool probe, git-only rejection. Same dual-leg assertion.

3. **A/B transaction diff**: `test/transaction-ab-test.sh` — a single fixture matrix exercising all 14 transaction scenarios on both legs, with stdout/stderr/exit/watched-state byte comparison (durations not present in transactions, unlike gate).

4. **Rollback**: `test/transaction-rollback-test.sh` — `SUBSTRATE_ENGINE=bash|go|auto` selects the correct leg; forced `go` with no binary fails closed; `SUBSTRATE_ENGINE_SKIP` is honored.

5. **Exit criteria**: `just battery` (full serial suite) green on both forced legs + `substrate verify` green after omp restart.

### Oracle self-containment (A1/A25)

Every Go-leg oracle builds its own binary:
```bash
BIN=$(go build -trimpath -buildvcs=false -o "$(mktemp -d)"/substrate-engine ./cmd/substrate-engine)
export SUBSTRATE_ENGINE=go SUBSTRATE_ENGINE_BIN="$BIN"
```
No PATH assumptions, no shared /tmp binary, unique build dirs.

## Assumptions & contingencies

- **P4a/P4b split**: P4 is split into P4a (checkpoint + restructure, this plan) and P4b (maintenance + A17 verbs, deferred). If the user prefers a single P4, the work items still hold — P4b just becomes W5+. The split rationale: maintenance is ~930 LOC across 6 bash files (comparable to P3's gate complexity which needed P3a/P3b); checkpoint's candidate-tree infrastructure is shared; and each phase independently landsable per the strangler pattern.

- **TS extension flip deferred to P4b**: Resolution 11 says "engine owns both sides of the lifecycle handshake; TS extension flips to engine spawn." This is deferred to P4b because: (a) the TS extension calls `.substrate/checkpoint.sh` directly (`transactions.ts:124`), which already delegates via the P4a seam — the TS layer is transparent to which engine handles it; (b) a direct engine spawn from TS is a separate coordination point better done once maintenance is also Go-owned. If the user wants the TS flip in P4a, it's a thin change: `transactions.ts` resolves the engine binary via the existing `resolveEngineCommand` pattern and spawns `substrate-engine checkpoint --json` instead of `bash .substrate/checkpoint.sh`. The `--json` output format stays identical.

- **No known A31 exceptions in checkpoint/restructure**: W1's audit may find some. Contingency: if an A31 exception is found, it gets its own commit with a dual-leg A/B scenario (per A34), fixing BOTH legs in the same batch. The `comm` locale bug was already fixed in P1. If the audit reveals the audit itself is incomplete (e.g., a race condition in the candidate tree), the oracle goes RED-first and the fix follows.

- **Lock interop**: Go uses `os.Mkdir` for the lock (same as `mkdir` in bash). The lock is cleaned up on success/failure via `defer os.RemoveAll(lockPath)`. If a bash-started transaction holds the lock, the Go leg sees `os.Mkdir` fail (equivalent to bash `mkdir` failing) and exits with the same error message. Cross-engine resume is NOT tested in P4a (checkpoint/restructure don't have resume — only maintenance does). Cross-engine lock contention is tested: a bash leg acquires the lock, the Go leg blocks with the same error.

- **Receipt delegation**: checkpoint's `write_gate_receipt` already delegates to the Go engine via `core/receipt-lib.sh`'s P2 seam. The Go checkpoint calls `internal/receipt.WriteCheckpointReceipt()` directly. No new receipt work in P4a.

- **Subagent file ownership** (operational note 5 from P3): files written exclusively by background `task` subagents can be missing from the ownership ledger. If this blocks the P4a checkpoint during implementation, re-write each affected file through a direct tool call before checkpointing. Budget for this.

## New amendments to the parent plan (binding)

- **A41 — P4a/P4b split.** P4 is split into P4a (checkpoint + restructure, this plan) and P4b (maintenance + A17 maintenance-lib engine verbs + TS extension flip). P4a lands first; P4b depends on `internal/transaction/candidate.go`. Landing P4a flips no parent phase — P4 stays `active` until P4b also lands, then flips to `committed`.

- **A42 — TS extension flip deferred to P4b.** Resolution 11 ("engine owns both sides of the lifecycle handshake; TS extension flips to engine spawn") is satisfied at P4a by the delegation seam (TS calls `.substrate/checkpoint.sh` which delegates to the engine). The direct engine spawn from TS is P4b scope. Rationale: the seam is transparent to TS; a direct spawn is a coordination point better done once all three transactions are Go-owned.

- **A43 — `substrate_engine_exec` gap in hooks** (recorded, not fixed in P4a). The hook scripts use `declare -F substrate_engine_exec` but `engine-shim.sh` does not define this function, so hooks always run bash. This is a pre-P4a condition, not introduced by P4a. P4a uses the proven P3 `substrate_engine_supports` pattern instead, avoiding the missing-function trap. The hook gap should be fixed before P5 (or at P5 when hook registrations are rewritten). P4a does not touch hooks.

## Acceptance

- [ ] checkpoint is byte-identical on both legs across git/jj, full-repo/path-scoped, accept-regression, session, rejection scenarios :: bash test/transaction-ab-test.sh
- [ ] restructure is byte-identical on both legs across split/describe/squash, session, rejection scenarios :: bash test/transaction-ab-test.sh
- [ ] the rollback switch is proven for checkpoint and restructure :: bash test/transaction-rollback-test.sh
- [ ] existing checkpoint and restructure suites pass on both legs zero-edit :: bash -c 'SUBSTRATE_ENGINE=go bash test/checkpoint-test.sh && SUBSTRATE_ENGINE=bash bash test/checkpoint-test.sh && SUBSTRATE_ENGINE=go bash test/restructure-test.sh && SUBSTRATE_ENGINE=bash bash test/restructure-test.sh'
- [ ] engine capabilities include checkpoint and restructure :: bash -c 'substrate-engine capabilities | grep -q checkpoint && substrate-engine capabilities | grep -q restructure'
- [ ] lock contention blocks correctly across legs :: bash test/transaction-rollback-test.sh
- [ ] hooks, ledger, and receipts are untouched by P4a :: bash -c 'bash test/ab-hooks-test.sh && bash test/golden-ledger-test.sh && bash test/receipt-test.sh'
- [ ] harness parity and vendor integrity hold :: bash -c 'bash test/parity-test.sh && bash test/vendor-drift-test.sh'

## Exit criteria

Every oracle checked, the full serial battery green on both forced legs, `substrate verify` green after an omp restart, the vendored mirror committed through its own maintenance transaction, then this plan flips to `committed` and the parent P4 section notes the P4a/P4b split. P4b (`maintenance`) begins from `internal/transaction/candidate.go`.