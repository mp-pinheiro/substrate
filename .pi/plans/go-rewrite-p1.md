# Plan: Go engine rewrite — P1 (engine skeleton + all seven hooks behind shims)
state: superseded
superseded-by: .pi/plans/go-rewrite-p2.md
issue: https://github.com/mp-pinheiro/substrate/issues/12
parent: .pi/plans/go-rewrite.md

## Goal
Land `cmd/substrate-engine` owning hook dispatch, the session-ledger state machine, the five PreToolUse policy guards, the comment-classifier hook path, and the changed-files-scan driver — reachable through in-script shims so `SUBSTRATE_ENGINE=auto|go|bash` selects the implementation and bash stays authoritative until P4. No behaviour change: the P0 A/B matrix is the merge gate.

Read first: `.pi/plans/go-rewrite.md` (12 binding resolutions, shared-artifact compat table, 30 amendments, Decided section), then `.pi/plans/go-rewrite-p0.md` (what P0 froze and why). Both are self-contained; no chat context is required.

## Files in scope
- `go.mod` (module `github.com/mp-pinheiro/substrate`), `cmd/substrate-engine/`, `internal/{canonjson,bashglob,xshell,logx,config,vcs,lifecycle,policy,comments,hook}/`.
- `substrate.json` (activate the `go` profile), `.golangci.yml` (rendered from the profile template), `justfile` (build recipe), `.substrate/**` (re-vendored).
- `core/hooks/*.sh` + `core/comment-ratchet.sh` — top-of-file shim only; policy bodies stay until P5.
- `core/doctor.sh` — engine-resolution diagnostic.
- `test/lib/ab-diff.sh` (dual-leg env mode, amendment A27), `test/ab-hooks-test.sh`, `test/golden-ledger-test.sh`, `test/engine-rollback-test.sh`.

## Operational notes for the implementer
Everything here was learned the hard way in the P0 session and is recorded because none of it is discoverable from the code alone.

1. **Vendored changes need two commits, in this order.** `substrate_checkpoint` REFUSES when an owned path is under `.substrate/**` ("agent-owned path is governed"). Commit the vendored mirror with `bin/substrate update --apply --checkpoint --message '<=50 chars'` (its own transaction is the authorized writer), then `substrate_checkpoint` the kit source.
2. **`update --apply` resumes and may skip re-rendering.** After reverting anything in `core/`, plain `--apply` can report success while `.substrate/` stays stale and `80-vendor-drift` reds. Use `bin/substrate update --apply --force`.
3. **Any `core/omp/*.ts` edit reds `substrate verify`** with "OMP loaded a different runtime — restart OMP". The installed extension outranks the one the running process loaded. Expected after every TS change; restart omp, then re-verify. It is not a code failure.
4. **Never `export` into the persistent shell; use `env VAR=… cmd`.** Two leaks in one session: a stale `HOME` from a probe sent the user-harness install into a temp dir, and a stale `AB_MODE=capture` silently overwrote the pristine A/B fixtures (recovered only by regenerating them from the pre-change tree via `git archive`).
5. **Subagent writes are owned by the parent — for blocking calls only.** Probed empirically: a blocking `agent()` inside `eval` wrote a file and the parent ledger gained it (`ownedPaths`), with no drift notice and no subagent commit. The tracked unit is the spawning tool (`task`/`eval` are absent from `TRACKING_READ_ONLY_TOOLS`, `runtime.ts:6-14`), and attribution is a full-tree diff (`substrate-quality.ts:349-352`). The fire-and-forget background `task` tool returns IDs immediately, so its bracket may close before the subagent writes — UNPROVEN, do not rely on it for writes. Ledger: `~/.omp/run/substrate-quality/<sha256(repoRoot)[:16]>.json` under `.task.ownedPaths`. Claude parity comes from `Task` being in the PostToolUse matcher (`core/claude-hooks.json:37`).
6. **CI toolchain provisioning is automatic — do not edit workflows.** Activating `go` in `substrate.json` is sufficient: `.github/workflows/substrate-gate.yml:31` runs `test/ci-toolchain.sh --active`, which executes the profile's own `ci` lines (`profiles/go/profile.json:12-17`: apt `golang-go` plus commit-pinned golangci-lint v2.12.2). Activation also renders `.golangci.yml` from the profile template.
7. **Go conventions the profile enforces.** forbidigo bans `fmt.Print*` everywhere — the `main.go` exclusion lifts only the panic rule — so protocol writers use `json.NewEncoder(os.Stdout)` or `fmt.Fprintf(os.Stdout, …)`. wrapcheck + errcheck + errorlint mean every error crossing a package boundary is wrapped and checked; depguard bans `github.com/pkg/errors`. Porting bash that ignores errors freely pays this per work item.
8. **The byte-parity oracle already exists.** `test/lib/ab-diff.sh` does capture/verify with normalization plus PATH-shim spawn counting; `test/expected/ab-stop/**` holds expectations captured from the PRE-batching engine; `test/ab-stop-test.sh` pins per-scenario jq/jj ceilings. Reuse it for the Go leg rather than writing a second harness. Capture mode must never run against a modified engine — that is how P0 lost its fixtures.
9. **Frozen artifacts and the pinned jq.** `test/golden/{baseline.json,metrics.jsonl,claims.0x1f,manifest.json}` were captured under bash 5.2 + sha256-pinned jq-1.7.1 (`test/ci-toolchain.sh --ensure-jq` installs it to `test/.toolchain/bin/jq`). Ambient `jq` is untrusted: the interactive harness shell resolves a jaq builtin while spawned scripts get `/usr/bin/jq` 1.7. A vector diff is a semantic decision, never a refresh.
10. **Never name a file `substrate-baseline.json` outside the repo root.** That basename is governed anywhere in the tree by design (it lets the guard rule on paths whose parents do not exist yet); the vector is `test/golden/baseline.json` for exactly this reason.
11. **Ledger caveat for the port:** `ownedPaths` retains an entry after its file is deleted (observed). Reconciliation happens at checkpoint time, so it is harmless today — but the Go `internal/lifecycle` port must decide this deliberately rather than inherit it by accident.

## Work items
1. **Foundation, one atomic commit (amendment A12).** `go.mod`, a minimal `cmd/substrate-engine` (`version` verb only), `substrate.json` += `go`, langmap regen, `.golangci.yml`, `justfile` build recipe, re-vendor. Acceptance for this step alone: `substrate gate` green with `.go` files tracked — `05-unclaimed-source`, `75-go-build`, `76-golangci`, and `30-budgets` all pass. Land this before writing any package.
2. `internal/canonjson` — jq byte-twin encoders: sorted-key compact (`jq -cnS`), insertion-order compact (`jq -cn`), and jq-1.7's invalid-UTF-8 → U+FFFD coercion. Golden-vector tested.
3. `internal/bashglob` — bash `case` glob semantics (`*` crosses `/`), the ONLY glob dialect in the engine (amendment: three dialects existed; bash wins).
4. `internal/xshell` + `internal/logx` — atomic write (mktemp beside dest, chmod --reference, mv), subprocess capture, and the exact `info`/`warn`/`success` output discipline.
5. `internal/config` — `substrate.json`, langmap, baseline allowance; fail-closed on corrupt config exactly as the hooks do.
6. `internal/vcs` — `jj`/`git` wrappers for the lifecycle and scan paths, reproducing `core.quotePath` handling for non-ASCII paths.
7. `internal/lifecycle` — the session-ledger state machine, byte-frozen against new vectors: revision probe, per-file SHA-256, fingerprint recipe, drift re-baseline, `trackingError` non-clobber. Port the POST-#11 semantics (A18: #11 is verified landed).
8. `internal/policy` — the five PreToolUse guards. POSIX ERE transliteration is split-on-newline + per-line RE2, never `(?m)` (amendment A6). Port the TS side only for the five deltas the contracts mark TS-correct; bash otherwise (A24).
9. `internal/comments` — the embedded classifier and ratchet, single-sourced for the hook path now and the P3 gate check later (resolution 12).
10. `internal/hook` — payload adapters, the changed-files-scan driver (content-hash memo per P0 0.2, engine-version in the namespace per A7), and stdout/exit protocol rendering.
11. **Shims** in the 8 ported scripts + re-vendor. `SUBSTRATE_ENGINE=bash` wins over everything; missing/unhealthy binary under `auto` falls back to bash with a doctor-visible warning; `SUBSTRATE_ENGINE_BIN` overrides location for dev builds (resolution 3). Registrations stay `bash .substrate/hooks/X.sh` until P5 (resolution 1).
12. `core/doctor.sh` — report the resolved engine, its version, and which leg `auto` would pick.
13. Session-ledger golden vectors + pinned capture script, including non-ASCII and invalid-UTF-8 paths (amendment A8).
14. A/B parity harness dual-leg mode (A27) — same stdin to both engines, identical stdout/stderr/exit/state.
15. Build wiring: `justfile`, a CI build job, and a dual-leg hook-parity job that provisions its toolchain via `test/ci-toolchain.sh` (amendment A29).

## Non-goals
- No receipt, gate-runner, or transaction work — P2, P3, P4.
- No hook-registration rewrite and no collapsing the four PreToolUse(Bash) entries (resolution 1 and 2).
- No policy semantics change; the A/B matrix must stay byte-identical.
- No `.substrate/` deletion and no removal of `80-vendor-drift`/`81-harness-parity` — P5.

## Acceptance
- [x] the go foundation is tracked, claimed, and the kit gate stays green with it :: bash -c 'test -f go.mod && test -f .golangci.yml && jq -e ".profiles | index(\"go\")" substrate.json >/dev/null && bin/substrate gate'
- [x] stop-branch output stays byte-identical on the bash leg :: bash test/ab-stop-test.sh
- [x] every ported hook answers on the Go leg with identical stdout, stderr, exit and state :: bash test/ab-hooks-test.sh
- [x] the session ledger is byte-identical to its committed vectors under the pinned toolchain :: bash test/golden-ledger-test.sh
- [x] setting SUBSTRATE_ENGINE=bash restores the bash leg for every hook :: bash test/engine-rollback-test.sh
- [x] frozen gate artifacts are unchanged by P1 :: bash test/golden-vectors-test.sh
- [x] the existing hook and lifecycle suites pass unmodified :: bash -c 'bash test/changed-scan-test.sh && bash test/vcs-hooks-test.sh && bash test/checkpoint-test.sh'
- [x] harness parity and vendor integrity hold :: bash -c 'bash test/parity-test.sh && bash test/vendor-drift-test.sh'

## Exit criteria
Every oracle above checked, `substrate verify` green after an omp restart, and the vendored mirror committed through its own maintenance transaction. Then flip this plan to `committed` and graduate P2 (`.pi/plans/go-rewrite-p2.md`) per amendment A2, which supersedes this one on landing.

## Landed 2026-08-06 — decisions made during implementation
- **Work item 8 scope resolved: bash everywhere, no TS deltas ported.** The "five TS-correct parity deltas" the contracts were meant to mark were not accessible in this session (the contract-extraction artifacts were session-local to the planning run). Since the merge gate is a byte-identical bash-vs-Go A/B harness, porting any TS-side behavior would have reddened it; every guard, the lifecycle ledger, and the classifier port bash bug-for-bug, including its quirks (see below). Revisit at P4 when the TS extension itself is retired.
- **`comm` locale bug found and fixed in `core/checkpoint.sh` and `core/restructure.sh`.** Both scripts sort operands with `LC_ALL=C sort` but invoked `comm` under the ambient locale; under a non-C `LC_ALL` (the default on most dev machines) `comm` reports "not in sorted order" and its diff becomes wrong, spuriously blocking checkpoints with many changed paths. Fixed by pinning `LC_ALL=C` on every `comm` call. Unrelated to the P1 scope but blocking to land it.
- **Bash bug reproduced deliberately, not fixed:** git renders non-ASCII paths as a quoted, C-escaped string (`"caf\303\251.txt"`) that `core/hooks/agent-lifecycle.sh` never unquotes, so the ledger's entry key is the literal quoted text and its value is `deleted` (no file exists under that name). `internal/vcs` never calls its own `UnquotePath` from the snapshot path for this reason. Frozen in `test/golden/ledger/git-invalid-utf8.json`.
- **Comment classifier exemption is real, not a bug:** a full-line comment immediately after a shebang inherits `prev_fullline=1` from the shebang's exempt branch, so `narration`/`restates-code`/`step-numbering` never fire on the FIRST comment line of a script. Test fixtures across this plan's own suites had to place slop comments after a real code line for exactly this reason.
- **Ownership-tracking gap for background subagents, confirmed live** (operational note 5 was right to flag it "UNPROVEN"): files written exclusively by background `task` subagents were absent from `~/.omp/run/substrate-quality/<hash>.json`'s `ownedPaths` even though genuinely dirty, causing `substrate_checkpoint` to build an incomplete candidate (missing whole packages, `go build` failed inside the gate). Recovered by re-writing each affected file's real content once through a direct (non-subagent) tool call, which re-registered ownership without changing final bytes. P2+ sessions that fan out heavy background work should budget for this.
