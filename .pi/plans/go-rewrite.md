# Plan: Go engine rewrite
state: draft
issue: https://github.com/mp-pinheiro/substrate/issues/12

## Goal
Replace the bash engine (6,725 LOC / 55 files, ~285 jq callsites, byte-identical 5,152-LOC `.substrate/` vendored copy) with one static Go binary (`substrate-engine`) while keeping external linters, `jj`/`git`, and user/profile `checks.d` bash scripts as subprocesses. Measured motivation (issue #12): ~106 ms and ~86 processes of hook overhead per Bash tool call in the agent loop; ~1,290-fork receipt fingerprint on every push/checkpoint including the cache-hit path; two whole subsystems (vendor-drift, harness-parity) that exist only because bash cannot ship a binary. Non-motivation: the gate's wall time (linter-dominated) — the rewrite targets the hook path, receipts, and the duplication taxes.

## Method
This plan was produced by a staged multi-agent workflow: 7 parallel subsystem contract extractions (hooks-bash, omp-ts, receipts, gate, transactions, maintenance, cli-install; 214 contracts, 128 byte-compat hazards, 114 untested contract points), a 3-lens architecture panel (migration seams / target architecture / distribution+ops) reconciled by 2 independent judges, 6 parallel phase work packages, and 4 adversarial reviews (byte-compat, self-gating, semantics, oracle executability) yielding 41 findings (21 high). The amendments section folds every accepted finding; where a phase section conflicts with an amendment, the amendment wins.

## Binding architecture resolutions
1. Seam (P1–P4): Claude hook registrations remain `bash .substrate/hooks/<X>.sh`; each ported script gains a top-of-file shim that `exec`s the engine for that hook identity. Registrations are rewritten only at P5.
2. Dispatch grammar: per-hook identity — `substrate-engine hook <name>`. No collapsed pre-bash dispatcher before P5: Claude composes same-matcher hooks in array order with independent exit codes; collapsing changes observable semantics.
3. Rollback switch: `SUBSTRATE_ENGINE=auto|go|bash` selects the implementation in the shims; `SUBSTRATE_ENGINE_BIN=<path>` overrides binary location (dev builds). `SUBSTRATE_ENGINE=bash` wins over everything; a missing/unhealthy binary under `auto` falls back to bash with a doctor-visible warning (fail-open on engine absence is safe pre-P5 because bash remains authoritative).
4. Binary identity: `substrate-engine`, resolved via a store dir + `.substrate/engine.json` redirect with flat schema `{version, binary_sha256, path?}` (same pinned-sha256 trust pattern as `core/install-gitleaks.sh`). Introduced at P2; doctor asserts the binary hash from then on. Multi-platform ships via per-host stores, not a platforms map (single flat schema, P2–P5 consistent).
5. `core/gate-lib.sh` survives P5 forever — user/profile checks source it. Post-P5 it is authored from a go:embed asset and byte-attested by the successor check. jq remains a pinned runtime dependency for user checks; doctor checks it.
6. `.substrate/` post-P5: `engine.json`, `gate-lib.sh`, `checks.d/`, `langmap.json`, `VERSION`, and 3-line exec shims for every path external callers reference. Vendored engine scripts are deleted.
7. Receipts: the fingerprint recipe is VERSIONED, never byte-chased — bash `printf %q` is locale-dependent, so byte-parity is a trap. The receipt gains an engine identity field; on engine upgrade or phase boundary, receipts regenerate (one extra gate run, self-healing). The P2 Go recipe fixes the %q/locale/ordering hazards deliberately; P5 replaces vendored-tree hashing in `engine_state_hash` with binary sha256 + gate-lib.sh + checks.d hashing.
8. Baseline, metrics JSONL, CLAIMS table: byte-compatible REQUIRED while any bash consumer remains — baseline pretty-print (jq default 2-space, key order `metrics` then `direction`), metrics JSONL insertion-order keys `{name,value,dir}`, CLAIMS 0x1F table including jq `tojson` entry key order. Frozen by golden-vector fixtures captured from pinned jq-1.7.1 + bash 5.2 under `LC_ALL=C` before P1 lands.
9. P5 rollback: one revert commit (registration rewrite, `.substrate/` re-render, and kit deletions land in a single maintenance commit); P5 receipts invalidate on revert and regenerate.
10. Live-session cutover: hook paths keep answering mid-session — the exec shims at old paths ARE the compatibility layer; nothing is deleted without a shim.
11. TS/omp boundary: the extension stays thin and spawns `substrate-engine <tool> --json --abi 1`; the engine supports one prior ABI major during transitions.
12. Comment classifier single-source: P1 embeds the classifier and routes the hook path (comment-ratchet) to it; the P3 gate check reuses the same embedded implementation; the bash gate-path copy dies at P3.

## Shared-artifact compatibility policy
| Artifact | Policy | Mechanism |
|---|---|---|
| `substrate-baseline.json` | byte-frozen | golden vectors (P0), byte-compare oracle at every phase |
| metrics JSONL | byte-frozen | golden vectors (P0) |
| CLAIMS 0x1F table | byte-frozen | `SUBSTRATE_CLAIMS_OUT` capture (P0) + vectors |
| session ledger (`agent-sessions/*.json`) | byte-frozen from P1 | Go writes, bash `checkpoint.sh` reads until P4 — cross-engine window; vectors incl. non-ASCII/invalid-UTF-8 paths |
| gate/maintenance receipts | versioned, regenerate-on-upgrade | engine identity field; invalidate-once at P2 and P5 |
| changed-files memo | keyed cache, never shared cross-engine | engine-version in namespace from P1 |
| Claude hook stdin/stdout/exit protocol | frozen forever | A/B parity harness |
| check env contract + gate-lib API | frozen forever | enumerated in P3; env-probe oracle |

## Phases
Each phase graduates into its own child plan (`.pi/plans/go-rewrite-p<N>.md`, `state: active`) when work starts, carrying the full oracle list as real checkboxes. Verification per landing: targeted suites named by the phase, then `substrate verify` green in this repo — including 80-vendor-drift and 81-harness-parity until P5 deletes them.

### P0 — bash-only palliatives + compatibility freeze (no Go)
Goal: cut the measured hot spots with zero behavior change and freeze the compatibility surfaces the port will be judged against.
- 0.1 Batch the stop-path ~28 jq into one decision jq (`core/hooks/agent-lifecycle.sh:206-263`); single-pass `@tsv` reads for the maintenance receipt N+1 loops (`maintenance-receipt.sh:69-107`, `maintenance.sh:32-39`, `maintenance-lib.sh:260-264`, `maintenance-transaction.sh:192-198`).
- 0.2 Key the changed-files memo on content sha256, not `mtime:size` (`core/hooks/changed-files-scan.sh:56-61,93-98`); regression test: same-size mtime-restored edit MUST rescan.
- 0.3 Recorded decision: Claude hook consolidation SKIPPED — P1 obsoletes it (resolution 2 forbids collapsing registrations anyway).
- 0.4 `SUBSTRATE_CLAIMS_OUT` emission in bash `gate.sh` so CLAIMS bytes are capturable; claims-table-test stops text-patching.
- 0.5 Golden-vector fixtures committed under `test/golden/` + pinned capture script (jq-1.7.1 static sha256-pinned into `test/.toolchain/bin`, bash 5.2 asserted at capture time; verification compares bytes only).
- 0.6 A/B diff harness skeleton (`test/lib/ab-diff.sh`) + stop-path scenario matrix; the env-flag dual-leg mode lands in P1 (amendment A27), not as an erroring stub.
- 0.7 `LC_ALL=C` pin on `core/maintenance-lib.sh:64,137` sorts (amendment A9) — documented one-time maintenance-receipt invalidation; no `incomplete` transaction may span the change.
Sequencing: issue #11 phases 0–1 touch the same files (agent-lifecycle, changed-files-scan) and change semantics — #11 lands FIRST; P0 rebases on it.
**LANDED 2026-08-05 — see `.pi/plans/go-rewrite-p0.md` (state: committed, 9 oracles green).** Measured result: whole stop hook 16 jq to 5 on clean paths, 24-29 to 6-8 on blocking paths, with all 12 scenarios byte-identical to the pre-batching engine. The "jq count <= 3" target above was mis-scoped: it described the decision block, while the harness counts the whole hook (payload parse + snapshot + batch + protocol writers); per-scenario ceilings now pin the measured totals. 0.3 consolidation skipped by resolution 2. Frozen vectors committed under `test/golden/` with a sha256-pinned jq-1.7.1. Sequencing note resolved: #11 was verified already landed (amendment A18), so P0 froze current semantics directly.

### P1 — engine skeleton + all seven hooks behind shims
Goal: `cmd/substrate-engine` (module `github.com/mp-pinheiro/substrate`, go.mod at repo root) owning hook dispatch, session-ledger state machine, policy guards, comment-classifier hook path, changed-files-scan driver.
- Packages: `internal/canonjson` (jq byte-twin: sorted-key compact, jq 1.7 invalid-UTF-8→U+FFFD rule), `internal/bashglob` (bash `case` glob semantics — the ONLY glob dialect), `internal/config`, `internal/vcs` (jj/git wrappers reproducing `core.quotePath` handling), `internal/lifecycle` (ledger, byte-frozen), `internal/policy` (guards; POSIX ERE transliteration = split-on-newline + per-line RE2, never `(?m)` — amendment A6), `internal/comments` (embedded classifier, resolution 12), `internal/hook` (adapters + protocol rendering), `internal/xshell`, `internal/logx`.
- Ports the POST-#11 lifecycle semantics; the five TS-correct parity deltas from the contracts port the TS side, everything else ports bash (amendment A24).
- In-script shims in the 8 scripts + re-vendor via the sanctioned update path; `SUBSTRATE_ENGINE`/`SUBSTRATE_ENGINE_BIN`/`SUBSTRATE_ENGINE_SKIP` honored identically in bash shims and TS resolveEngineCommand (amendment A23).
- Session-ledger golden vectors (incl. non-ASCII paths) + A/B parity harness: same stdin → both engines → identical stdout/stderr/exit/state.
- Gate self-hosting: go.mod + `.go` files land WITH go-profile activation in `substrate.json` + langmap regen + re-vendor in the SAME commit, or 05-unclaimed-source reds the kit gate (amendment A12).
- Build wiring: justfile, CI build job, dual-leg hook-parity job (provisions toolchain via `test/ci-toolchain.sh` — amendment A29).
- Code conventions bound by the go profile (`profiles/go/templates/golangci.yml`): forbidigo bans `fmt.Print*` everywhere (the `main.go` exclusion lifts only the panic rule) — protocol writers use `json.NewEncoder(os.Stdout)` / `fmt.Fprintf(os.Stdout, ...)`; wrapcheck + errcheck + errorlint mean every error crossing a package boundary is wrapped and checked — porting bash that ignores errors freely pays this per work item. State both in the P1 child plan before drafting porters.
Key oracles: A/B parity across the hook scenario matrix on both legs → `bash test/ab-hooks-test.sh`; ledger vectors byte-green → `bash test/golden-ledger-test.sh`; every oracle self-builds (`go build -o <mktemp-dir>/substrate-engine ./cmd/substrate-engine && env SUBSTRATE_ENGINE=go SUBSTRATE_ENGINE_BIN=... bash test/...`) — no PATH/`just` assumptions, unique build dirs (amendments A1, A25).
Workflow: fan out one porter per package with the contract file as spec; A/B harness is the merge gate; enemy pass on `internal/policy` regex transliteration and `internal/lifecycle` before shims flip on.
**LANDED 2026-08-06 — see `.pi/plans/go-rewrite-p1.md` (state: committed, 8 oracles green).** All ten packages plus `internal/hook` landed with real bash-vs-Go differential proof (policy: 54 vectors; comments: 167-file sweep; canonjson: pinned-jq golden vectors + randomized differential; bashglob: bash-verified table). Work item 8's "five TS-correct deltas" were not portable this session (contract artifacts were session-local to the planning run) — every guard, the ledger, and the classifier port bash bug-for-bug instead, since the A/B harness is byte-identical-or-red; revisit at P4. Two pre-existing bugs found and fixed while landing: a `comm` locale bug in `core/checkpoint.sh` and `core/restructure.sh` (both sorted operands with `LC_ALL=C` but ran `comm` under the ambient locale, spuriously blocking checkpoints); and a confirmed (not hypothetical) ownership-tracking gap where files written only by background `task` subagents were absent from the session ledger, recovered by re-writing them through a direct tool call.

### P2 — receipts in-process + engine attestation
Goal: exact-state receipt authority moves to Go behind the P1 seam; recipe v2 (versioned per resolution 7) fixes %q/locale/ordering hazards; `engine.json` + doctor attestation land.
- `internal/receipt` (v2 hashers, state document, fingerprint), receipt verbs on the CLI, push-gate/gated-push/gitleaks-deep routed through the engine via shims; gitleaks deep-scan cache key stays byte-identical to bash and the shim keeps the frozen argv grammar (amendment A28).
- `.substrate/engine.json` (flat schema, resolution 4) + `internal/enginepin` + doctor attestation; engine.json is NOT in 80-vendor-drift's compare list (it is generated per-repo, not vendored source) — doctor owns it (amendment: corrects P4's false claim).
- Invalidate-once migration: existing receipts regenerate on first post-P2 gate; every consumer (push-gate, checkpoint, maintenance-receipt readers) updated in the same commit.
- Doctor oracle must be non-vacuous: asserts the attestation link specifically, failing before the work exists (amendment A26).
Key oracles: six receipt-touching suites green on both legs; push cache-hit path exercises the Go fingerprint; receipt schema v2 round-trip.
Workflow: single porter + one enemy dedicated to the fingerprint recipe (the highest-risk byte surface); cross-engine window test (bash writes / Go judges, Go writes / bash judges) before shims flip.

### P3 — gate-runner bookkeeping in Go
Goal: the engine owns preflight, inventory, CLAIMS, check spawn/scheduling/reporting, metrics, ratchet, baseline writes; checks stay spawned bash; gate-lib.sh gets ZERO byte changes (engine feeds it).
- Inventory bug-for-bug (one sanctioned divergence documented); CLAIMS builder against P0 vectors; spawn protocol exporting the FROZEN env contract enumerated from the gate contract file (env-probe oracle asserts every variable).
- FIFO scheduler with deterministic name-order reporting; ratchet algebra + baseline byte-compat (`--update-baseline`/`--tighten`/`--accept-regression`).
- Native checks: 05/15/30/40 + 10-comments (on the P1 classifier). Native dispatch is REGISTRY-driven: embedded name+digest registry merged with discovered `checks.d/` files; a non-matching discovered file wins (user override, doctor-warned) — natives never depend on file presence (amendment A11).
- Boundary metric movement uses `--accept-regression=<metric>` keyed form; bare `--update-baseline` refuses over a regression (amendment A3).
Key oracles: full suite + selftest green on BOTH legs with zero test edits; scheduler determinism; env probe; ratchet bug-pins.
Workflow: two porters (runner core / native checks) + enemy on the ratchet algebra; baseline vectors are the merge gate.

### P4 — transactions in Go
Goal: checkpoint/restructure/maintenance state machines ported; engine owns both sides of the lifecycle handshake; TS extension flips to engine spawn (resolution 11).
- `internal/transaction` (checkpoint, candidate-tree mode, restructure), verbatim jj/git subprocess inventory preserved; `internal/maintenance` (state model, manifest, candidate, apply, exact-commit, receipts, predicates, resume, sync, selfupdate + `internal/store` with flat engine.json — amendment A10).
- `maintenance-lib` engine verbs (`verify-transition`, `receipt-matches`, ...) implementing the bash argv/exit contract — P5's shims depend on them (amendment A17).
- Lock interop and cross-engine resume tests; A/B transaction diff via the ab-diff env-flag mode.
- All Go-leg oracles self-build with unique dirs and explicit `SUBSTRATE_ENGINE_BIN` (amendments A1, A25 — corrects the drafted oracles 6–10/13–15).
Key oracles: full suite green under both legs zero-edit; lock contention pinned; cross-engine resume (bash-started maintenance transaction recovered by Go engine and vice versa).
Workflow: one porter per state machine, contract file as spec; enemy on guard-order/error-string fidelity (agents parse these strings).

### P5 — cutover + deletion
Goal: one maintenance-transaction commit per repo rewrites Claude registrations to the engine, re-renders `.substrate/` to the resolution-6 layout, deletes the vendored bash engine + 80-vendor-drift + 81-harness-parity (successor: engine attestation check), and the kit repo deletes `core/*.sh` engine sources.
- `substrate asset` subcommand exposes embedded gate-lib.sh/checks; bin/substrate becomes a launcher; installer/doctor/report/selftest/audit port-or-retain per the cli-install contract (explicit table); `install-substrate.sh` + `install-jq.sh` pinned installers; consumer CI template.
- `--route`/stand-down spec written ONCE here (user-scoped launcher): payload path extraction, upward walk, per-hook stand-down matching BOTH bash-form and engine-form project registrations — no double-fire (amendment A16).
- Attestation: fail-closed links except the binary-hash link downgrades to a doctor-visible warning for `0.0.0-*` dev builds or `SUBSTRATE_ENGINE_BIN` overrides (amendment A14).
- Receipt recipe change: engine identity replaces vendored-tree hashing (resolution 7).
- Test edits are NOT zero: receipt-test.sh, restructure-test.sh, jj-hooks-test.sh, audit-test.sh (+ bootstrap-test's `source` of core libs) get targeted rewrites to drive engine verbs (amendment A13).
- Live-cutover + rollback rehearsal tests define provenance explicitly: synthesize the pre-P5 world from the P5-parent revision in a scratch clone; CI workflow sets fetch depth accordingly (amendment A30).
- 20-duplication/45-contract-drift/50-gitleaks: ported native in P5 scope (or the render keeps them as vendored bash under checks.d — decide at P5 start; they MUST NOT silently vanish) (amendment A11 counterpart).
Key oracles: post-cutover `.substrate/` contains no engine scripts; registrations contain no `.substrate/hooks/` spawns; attestation check green; single-revert rollback rehearsed green.
Workflow: enemy-first (attack the cutover commit plan before executing), then a single implementing agent — this phase is one atomic transaction, not a fan-out.

## Adversarial amendments (binding, override phase text)
- A1 Oracle self-containment: every Go-leg oracle builds its own binary (`go build -o "$(mktemp -d)"/substrate-engine ./cmd/substrate-engine`), exports `SUBSTRATE_ENGINE_BIN`, assumes no PATH/`just`; audit CI executes oracles verbatim and has neither.
- A2 Plan lifecycle: child plan per phase; landing phase N+1 flips N `committed` → `superseded` with `superseded-by:` pointer (committed plans re-execute forever in audit; P1's bash-leg oracles cannot outlive P5).
- A3 Boundary metric movement: `--accept-regression=<metric>` keyed form; the gate refuses `--update-baseline` over a regression (`core/gate.sh:262-264`).
- A4 Byte-comparing tests use ONLY the repo-local pinned jq (`test/.toolchain/bin/jq`, sha256-pinned 1.7.1); ambient `jq` may be jaq (it is on the primary workstation).
- A5 No `go test` acceptance oracles: the oracle layer stays e2e bash driving engine verbs; `go vet`/`go build` allowed in the CI build job. Internal Go tests need an explicit user waiver (open decision 1).
- A6 grep -E transliteration: split-on-newline + per-line RE2 match; `(?m)` is wrong (RE2 spans newlines that line-oriented grep never sees); A/B fixtures exercise newline-bearing commands per guard.
- A7 P1 scan driver keys the memo exactly as post-P0 bash (content sha256); memo namespace carries engine version from P1 (never shared cross-engine).
- A8 canonjson carries jq 1.7's invalid-UTF-8 → U+FFFD coercion; `internal/vcs` reproduces git `core.quotePath` handling; vectors include non-ASCII and invalid-UTF-8 paths.
- A9 `LC_ALL=C` maintenance sort pin lands in P0 (one-time receipt invalidation, documented).
- A10 engine.json schema is flat `{version, binary_sha256, path?}` everywhere P2–P5; per-host stores handle platforms.
- A11 Native checks dispatch by embedded registry, not file presence; 20/45/50 explicitly accounted for at P5 (native or still-vendored — never silently dropped).
- A12 First Go commit activates the go profile (or ledgers Go paths) + langmap regen + re-vendor atomically, or the kit gate reds on 05-unclaimed-source.
- A13 P5 edits four test suites (receipt, restructure, jj-hooks, audit) — the zero-edit claim was false (they `source` core libs the sweep deletes).
- A14 Dev-build attestation downgrade (0.0.0-*, SUBSTRATE_ENGINE_BIN) to warning; all other links fail-closed.
- A15 TS→engine per-event ABI (tool_call/tool_result/session_stop/before_agent_start subcommands with I/O schemas) is a named work item before the TS compute layer is deleted.
- A16 `--route`/stand-down specified once (P5); matcher covers both registration forms.
- A17 `maintenance-lib` engine verbs are P4 scope; P5 shims consume them.
- A18 RESOLVED 2026-08-05: #11 is landed in source — 0.1 xd:// exclusion (`runtime.ts:50`), 0.2 trackingError non-clobber (`substrate-quality.ts:324`), 0.3 reconcileInitial, 0.4 anchored commit regex (`protect-command.sh:24`), L3 rebaseline, path-scoped candidate mode (`checkpoint.sh`), per-root runtime state (`identity.ts:52-53`), stop-hook auto-checkpoint, L2 restructure. P1 ports current semantics; no re-land cost.
- A19 Session-ledger bytes are a frozen surface from P1 through P4 (bash checkpoint.sh reads Go-written state); reader/writer pairs per phase window are traced in the P1 child plan.
- A20 protect-command port reproduces whatever regex behavior is current at P1 time (post-#11 0.4 expected); vectors updated with #11.
- A25 Parallel-audit safety: unique build dirs per oracle (no shared /tmp binary; ETXTBSY).
- A26 Doctor oracles assert the specific new link (non-vacuous, fail-before).
- A27 ab-diff dual-leg env-flag mode is P1 scope (P4 depends on it; no erroring stubs).
- A28 gitleaks-deep shim keeps the frozen argv grammar; engine identity comes from engine.json only.
- A29 Hook-parity CI job provisions its toolchain (scratch-repo gates fail closed on missing tools).
- A30 Cutover/rollback rehearsal provenance: pre-P5 world synthesized from the P5-parent revision; CI fetch depth set.

## Decided (2026-08-05, session ruling — user directed "proceed")
1. Internal Go tests: NARROW WAIVER — `go test ./internal/...` allowed for golden-vector byte tests and state-machine transition tables only, run in the CI build job; the acceptance/oracle layer stays e2e bash (A5 unchanged). Fallback if revisited: hidden `substrate-engine debug <encoder>` verbs driven from bash.
2. Go profile: ACTIVATE at P1, same commit as `go.mod` (A12). Grounded: activation adds `75-go-build.sh` + `76-golangci.sh`; check count is light but lint impact is real — see the P1 conventions line (forbidigo/wrapcheck/errcheck). CI provisions go + golangci-lint in P1 build wiring.
3. engine.json: FLAT single-platform `{version, binary_sha256, path?}` (A10). Per-host stores absorb platform variance; revisit only when release automation needs a matrix.
4. #11 sequencing: DEPENDENCY SATISFIED — every #11 phase verified landed in source (see A18). Remaining action for the user: review and close #11 or split residuals; P1 freezes current semantics.

## Non-goals
- No policy-semantics, gate-contract, receipt-guarantee, or ratchet-model changes — host-language change only.
- Linters, jj, git stay subprocesses; no libgit2/jj-lib embedding; no daemon.
- `checks.d` user extension contract stays bash-compatible; profile authors never need Go.
- No auto-push changes; publication stays user-owned.

## Acceptance
- [ ] engine binary pinned and attested :: bash -c 'grep -q "\"version\"" .substrate/engine.json && grep -q "\"binary_sha256\"" .substrate/engine.json'
- [ ] vendored bash engine deleted :: bash -c '! test -e .substrate/gate.sh && ! test -e .substrate/checkpoint.sh && ! test -e .substrate/hooks/agent-lifecycle.sh'
- [ ] hook registrations no longer spawn per-hook bash scripts :: bash -c '! grep -q ".substrate/hooks/" .claude/settings.json'
- [ ] duplication-tax checks retired :: bash -c '! test -e checks.d/80-vendor-drift.sh && ! test -e checks.d/81-harness-parity.sh'
