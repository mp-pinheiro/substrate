# Plan: Go engine rewrite — P4b (maintenance + A17 verbs + TS flip + A43 hook exec gap)
state: active
issue: https://github.com/mp-pinheiro/substrate/issues/12
parent: .pi/plans/go-rewrite.md

Port the maintenance transaction state machine (~930 LOC across 6 bash files) from bash to Go, implement A17 maintenance-lib engine verbs, fix the A43 `substrate_engine_exec` hook gap, and flip the TS extension to direct engine spawn. Completes P4 (transactions); P5 (cutover + deletion) follows.

Read first: `.pi/plans/go-rewrite.md` (resolutions 1–12, A1–A43), then `.pi/plans/go-rewrite-p4a.md` (checkpoint + restructure patterns, `internal/transaction/candidate.go` shared infra).

## Context

P4a ported checkpoint (~268 LOC bash) and restructure (~234 LOC bash) to Go behind capability-probe delegation seams. The maintenance subsystem wraps those two: it evolves managed repo assets (`.substrate/`, profiles, `.claude/`, `.omp/`, CI workflows) over time, rendering them from profiles/kit sources into a candidate tree, gating the candidate, applying changed units to the worktree, exact-path committing, and syncing external phases (repo runtime, user harness). It is the kit's self-update mechanism and the primary user-facing maintenance command (`substrate bootstrap|init|update`).

The six bash files:
| File | LOC | Role |
|---|---|---|
| `core/maintenance.sh` | 301 | Entry point + resume incomplete |
| `core/maintenance-lib.sh` | 377 | Core library: path state, manifest, apply, dirty paths |
| `core/maintenance-receipt.sh` | 117 | Receipt validation, transition verification |
| `core/maintenance-sync.sh` | 59 | External sync phases |
| `core/maintenance-transaction.sh` | 258 | Candidate rendering, gating, apply, exact commit |
| `core/maintenance-cli.sh` | 87 | Argument parsing |

A43 gap: 8 hook scripts call `declare -F substrate_engine_exec >/dev/null 2>&1 && substrate_engine_exec <name> "$@"` but `engine-shim.sh` never defines `substrate_engine_exec`. The hooks always fall through to bash. Fix: define `substrate_engine_exec` in `engine-shim.sh`.

A42 TS flip: `transactions.ts` calls `.substrate/checkpoint.sh`, `.substrate/restructure.sh`, and `.substrate/maintenance-lib.sh repository-receipt-matches`. After P4b, all three transactions are Go-owned — flip to direct engine spawn via `resolveEngineCommand`.

## Approach

### Seam shape (E1)

`core/maintenance.sh` gains a capability-probe delegation block same as P4a D1 / P3 C1:

```
ENGINE_MODE=${SUBSTRATE_ENGINE:-auto}
if substrate_engine_supports maintenance; then
    if [ "$ENGINE_MODE" = "go" ] || [ "$ENGINE_MODE" = "auto" ]; then
        substrate-engine maintenance "$@"
        rc=$?
        [ "$rc" -eq 2 ] && die 'engine maintenance returned unknown-verb after capability probe'
        exit "$rc"
    fi
elif [ "$ENGINE_MODE" = "go" ]; then
    die 'SUBSTRATE_ENGINE=go but no engine binary found or capability probe failed'
fi
```

### Package structure (E2)

New package `internal/maintenance`:

- `engine.go` — `RunMaintenance(ctx, args) int`; the main state machine
- `args.go` — arg parsing (port of `maintenance-cli.sh`)
- `manifest.go` — `BuildManifest`, `ManifestAdd`, manifest helpers
- `pathstate.go` — `PathState(path) string` — deterministic path state hashing
- `dirty.go` — `CollectDirtyPaths`, `EntriesJSON`, `JSONFingerprint`, classification
- `candidate.go` — `OverlayWorktree`, `PrepareCandidate`, `RenderCandidate`, `GateCandidate`, `CandidateChanges`, `ChangedUnits`
- `units.go` — `UnitsJSON`, `UnitsMatchPreimage`
- `receipt.go` — `ReceiptJSON`, `PublishReceipt`, `UpdateReceipt`, `MarkUnitApplied`, `VerifyTransition`, `RepositoryReceiptMatches`, `ReceiptMatches`, `CompareDirtyState`
- `apply.go` — `ApplyUnit`, `ApplyUnits`
- `commit.go` — `CommitExact`
- `overlap.go` — `DirtyPathRepairable`, `DirtyPathSeedable`, `AppliedPathAuthorized`
- `sync.go` — `SyncExternalUnits`, `SyncUserLocked`, `FinishOutput`
- `resume.go` — `ResumeIncomplete`
- `types.go` — shared types
- `store.go` — metadata dir, VCS, revision, write_json, lock

Reuse: `internal/transaction.Candidate` (git archive + tar + overlay + seed + gate), `internal/vcs`, `internal/xshell`, `internal/canonjson`, `internal/receipt`, `internal/config`.

### A17 engine verbs (E3)

Three new verbs under `maintenance` subcommand:
- `maintenance verify-transition <from> <to> <fingerprint>`
- `maintenance repository-receipt-matches`
- `maintenance receipt-matches`

### A43 fix (E4)

Add `substrate_engine_exec` to `core/engine-shim.sh`:

```bash
substrate_engine_exec() {
    local engine=""
    if [ -n "${SUBSTRATE_ENGINE_BIN:-}" ] && [ -x "$SUBSTRATE_ENGINE_BIN" ]; then
        engine="$SUBSTRATE_ENGINE_BIN"
    elif engine=$(command -v substrate-engine 2>/dev/null) && [ -n "$engine" ]; then
        :
    else
        return 1
    fi
    exec "$engine" hook "$@"
}
```

### TS extension flip (E5)

`transactions.ts` replaces `.substrate/*.sh` calls with direct `substrate-engine` spawns via `resolveEngineCommand`.

## Work Items

### W0 — plan only

Land this file. Update `go-rewrite.md` P4 section.

### W1 — A43 fix + engine-shim.sh
- [ ] substrate verify green after omp restart :: bash -c 'SUBSTRATE_ENGINE=go substrate verify && SUBSTRATE_ENGINE=bash substrate verify'
Add `substrate_engine_exec` to `core/engine-shim.sh`. Re-vendor.

Gate: `test/ab-hooks-test.sh` green on both legs.

### W2 — foundation package

`types.go`, `args.go`, `store.go`, `pathstate.go`, `manifest.go`, `dirty.go`, `overlap.go`. Smoke: byte-identical output to bash counterparts.

### W3 — transaction core

`candidate.go`, `units.go`, `apply.go`, `commit.go`, `receipt.go`, `sync.go`, `resume.go`. Smoke: full maintenance cycle on scratch repo.

### W4 — engine.go + main.go verbs + delegation seam

`engine.go` (RunMaintenance), main.go dispatch, `maintenance` capability, delegation seam in `core/maintenance.sh`.

Gate: `test/maintenance-test.sh` dual-leg green.

### W5 — A/B + rollback oracles

`test/maintenance-ab-test.sh`, `test/maintenance-rollback-test.sh`, `test/maintenance-receipt-ab-test.sh`.

### W6 — TS extension flip

Replace `.substrate/*.sh` calls with direct engine spawns. Verify TS compiles.

### W7 — CI + integration + finalize

`maintenance-parity` CI job, full battery, `substrate verify`, plan → committed.

## Acceptance

- [ ] `substrate_engine_exec` defined :: grep -q "substrate_engine_exec()" .substrate/engine-shim.sh
- [ ] maintenance dual-leg green :: bash test/maintenance-test.sh
- [ ] A/B diff green :: bash test/maintenance-ab-test.sh
- [ ] rollback switch proven :: bash test/maintenance-rollback-test.sh
- [ ] A17 verbs dual-leg :: bash test/maintenance-receipt-ab-test.sh
- [ ] hooks still green :: bash test/ab-hooks-test.sh
- [ ] capabilities include maintenance :: substrate-engine capabilities | grep -q maintenance
- [ ] TS compiles :: npx tsc --noEmit
- [ ] full battery green both legs :: just battery
