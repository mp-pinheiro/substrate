# Plan: Go engine rewrite — P5a (Claude cutover + vendored bash deletion)
state: active
Issue: https://github.com/mp-pinheiro/substrate/issues/12
Parent plan: `.pi/plans/go-rewrite.md` (P5 section, resolutions 1–12, amendments A1–A43)
Preceding: `.pi/plans/go-rewrite-p4b.md` (state: committed). P5 is split per the 2026-08-09 user ruling: **P5a = Claude-side cutover (this plan)**; P5b = A15 omp-TS shim + go:embed asset subcommand (separate follow-up plan).

## Context

P1–P4b landed the Go `substrate-engine` binary owning hooks, receipts, the gate runner, checkpoint, restructure, and maintenance behind delegation seams (`core/engine-shim.sh`'s `substrate_engine_exec`/`substrate_engine_supports`). Bash bodies survive as `_v1` rollback legs. `.substrate/` is still a byte-identical 5,152-LOC vendored copy of `core/` enforced by `checks.d/80-vendor-drift.sh`. `.claude/settings.json` still spawns `bash .substrate/hooks/X.sh` (10 registrations). `checks.d/81-harness-parity.sh` still enforces bash↔TS mirror parity.

P5a cuts over the Claude/governance side so the four issue-#12 acceptance criteria pass: (1) engine pinned — already satisfied by `engine.json`; (2) `.substrate/gate.sh`, `.substrate/checkpoint.sh`, `.substrate/hooks/agent-lifecycle.sh` no longer exist; (3) `.claude/settings.json` contains no `.substrate/hooks/` spawns; (4) `checks.d/80-vendor-drift.sh` and `checks.d/81-harness-parity.sh` are retired. The omp TS extension keeps its in-process fast paths (runtime.ts/policy.ts/lifecycle.ts/identity.ts) behind a **transitional engine↔TS parity successor** check until P5b flips it to an A15 engine shim. `selftest`/`audit`/`report` are retained bash (the engine exposes no such verbs); they are edited to call the engine `gate` verb instead of the deleted `.substrate/*.sh`.

End state: every governed entry point (`bin/substrate gate|checkpoint|restructure|verify|selftest|audit`, all Claude/omp hooks, CI) spawns `substrate-engine` directly or a retained thin bash wrapper that delegates to it; `.substrate/` contains only the retained-layout files; `core/*.sh` engine bodies (those whose logic now lives solely in the binary) are deleted from the kit; the binary's sha256 pin in `.substrate/engine.json` is the trust root.

## Decided (2026-08-09, user ruling)

- **Scope split:** P5a = Claude cutover + vendored bash + duplication-tax deletion; P5b = A15 per-event omp-TS shim + go:embed `asset` subcommand + transitional-parity deletion. Mirrors the P4a/P4b precedent.
- **Push-gate/receipt/gitleaks wrappers (verified, critique fix):** `push-gate.sh`, `gated-push.sh`, `gitleaks-deep.sh`, `gitleaks-lib.sh`, `receipt-lib.sh` are NOT engine verbs (`cmd/substrate-engine/main.go` has no such verbs; `receipt` subverbs are `fingerprint|matches|write` only). RETAIN all five as thin delegated bash wrappers in BOTH `core/` and `.substrate/`; they already route internal calls to `substrate-engine receipt matches`/`gate`/`gitleaks-deep-key` via the P2 seams. Do NOT delete them. The acceptance criteria do not require them gone.
- **20/45/50 checks:** KEEP as vendored bash under `.substrate/checks.d/` (they wrap external subprocesses — jscpd, gitleaks, regen+diff — so a Go port buys no in-process win; `checks.d` stays bash-compatible per the non-goals; A11 never-silent-drop honored). No `internal/gate/check_20/45/50` work.
- **Distribution transparency:** binary + sha256 pin only (the issue's floor). The Go source tree is NOT vendored into `.substrate/`; it lives in the kit repo (`cmd/`, `internal/`) and consumer repos install via a pinned-binary installer (P5b's `install-substrate.sh`). Vendored bash is gone, replaced by the attested binary.
- **selftest/audit/report:** RETAINED as bash in `core/` + `.substrate/`; edited to call `substrate-engine gate` (and, where they inspect receipts, the engine `receipt` verbs) instead of deleted `.substrate/*.sh`. Porting them to Go engine verbs is P5b+.

## Approach

The cutover is one atomic repository maintenance transaction. Order steps so the tree builds and the gate stays green after each checkpoint boundary; the final cutover commit lands in a single maintenance commit (resolution 9: P5 rollback is one revert). Independent steps are marked `[I]`.

### Step 1 — Engine verbs owned by the binary (verified)

Verified against source this session. The engine dispatch (`cmd/substrate-engine/main.go:30-113`) exposes exactly: `version, receipt, gitleaks-deep-key, pin, hook, gate, checkpoint, restructure, maintenance, capabilities`. The `receipt` subverbs are `fingerprint|matches|write` ONLY (`internal/receipt/dispatch.go:30-35`). There is **no** `push-gate`, `gated-push`, `gitleaks-deep`, or `selftest/audit/report` verb. Consequences for P5a:
- `gate`, `checkpoint`, `restructure`, `maintenance`, `hook` ARE verbs → `bin/substrate` execs the binary for these; the corresponding `core/*.sh` + `.substrate/*.sh` are DELETABLE (Step 5).
- `push-gate`, `gated-push`, `gitleaks-deep`, `gitleaks-lib`, `receipt-lib` are NOT verbs → these bash scripts are RETAINED as thin wrappers (they already delegate internal calls to `substrate-engine receipt matches`/`gate`/`gitleaks-deep-key` via the P2 seams; see Step 6). They stay in `core/` AND vendored into `.substrate/`.
- `selftest`, `audit`, `report` are NOT verbs → retained bash wrappers, edited to call `substrate-engine gate` (Step 6).
- `bin/substrate baseline` → `exec substrate-engine gate --update-baseline|...`; `bin/substrate verify` → `verify_omp_runtime` (TS, unchanged) + `substrate-engine gate`.

Gate exit-code contract (verified `internal/gate/runner.go`): **0** = all checks passed; **1** = one-or-more checks failed (findings, `runner.go:128`); **3** = infrastructure error (inventory/claims/checks build or read failure, `runner.go:48,56,63,85`); **12→2** = usage/parse error (preflight/`ParseFlags` return 12, remapped to 2 by `main.go:51-54`). Callers and assertions that key on a findings exit code MUST use **1**, not 3. No engine verb changes needed in P5a.

### Step 1b — Binary resolution at hook-fire time `[I]`

A consumer repo firing a Claude hook runs `substrate-engine hook <name>` (bare name, Step 2). The binary must be resolvable. Today `core/engine-shim.sh` resolves `SUBSTRATE_ENGINE_BIN` → `command -v substrate-engine`; post-cutover the registration resolves by PATH. Reuse the kit's `core/install-gitleaks.sh` pinned-binary pattern: `bootstrap`/`update` installs the binary to `$HOME/.substrate/bin/substrate-engine` (or a store dir), verifies sha256 against `.substrate/engine.json`, and writes a `substrate-engine` PATH shim so the bare command resolves. `doctor.sh` already attests the pin (Step 12); add a doctor line asserting the PATH shim resolves to the pinned binary. The user-level `substrate-launch.sh` (Step 7) resolves via the same mechanism before exec. DECIDED: P5a uses the PATH shim (simplest, matches the installers); the `engine.json` `path?` direct field is a P5b release-automation concern.

### Step 2 — Rewrite `.claude/settings.json` registrations to spawn the engine

Rewrite `core/claude-hooks.json` (the template `install_hooks_config` renders) so every hook command spawns the engine:
```
"command": "substrate-engine hook <name> [subverb]"
```
The 8 registrations become (preserving matchers and array order — resolution 2 forbids collapsing same-matcher groups):
- PreToolUse `Write|Edit` → `substrate-engine hook protect-paths`
- PreToolUse `Bash` (array, 4 entries, order kept): `protect-command`, `enforce-jj`, `enforce-conventional-commits`, `gate-before-push`
- PostToolUse `Bash|Write|Edit|MultiEdit|NotebookEdit|Task` (array, 2): `agent-lifecycle observe`, `changed-files-scan`
- SessionStart → `agent-lifecycle start`
- Stop → `agent-lifecycle stop`
- SessionEnd → `agent-lifecycle end`

`bin/substrate` must be on `PATH` at hook time. The bootstrap installs the binary to the kit's `bin/` (or a store dir) and ensures `PATH` includes it; consumer pin is `.substrate/engine.json` (a `path?` field may point at the installed binary). The hook command uses bare `substrate-engine` (resolved via `PATH`/`engine.json`); it does NOT reference `.substrate/hooks/`. The user-level template `core/claude-hooks-user.json` mirrors this (kept by `install_user_harness`); its `substrate-launch.sh` dispatcher gains engine-form recognition (Step 7).

Update `merge_hook_groups` (in `core/install-lib.sh:68-88`) so the strip regex recognizes BOTH the old bash-form managed commands (to remove them on re-bootstrap) AND the new engine-form: add `or ($command | test("^substrate-engine hook [A-Za-z0-9._-]+([ ][A-Za-z0-9._-]+)*$"))` (exact verb grammar and subverb `observe|start|stop|end`). Old-form strip regexes are KEPT through P5a so a re-bootstrap of a still-bash repo cleans up; they are removed in P5b.

### Step 3 — Migrate `bin/substrate` engine commands to exec the binary

`bin/substrate` is retained as the kit bash launcher/installer. Its governing commands stop `exec`ing `.substrate/*.sh` and `exec` the binary instead (or a thin retained wrapper for selftest/audit/report):
- `cmd_gate` (line 330-344): replace `.substrate/gate.sh` exec with `exec substrate-engine gate "$@"`. For `--deep`: `substrate-engine gate` then `exec .substrate/gitleaks-deep.sh` (retained wrapper) for the actual deep scan. Keep the `--deep --no-cache|--print-key` arg guard.
- `cmd_checkpoint` (line 399): `exec substrate-engine checkpoint "$@"` (P4a verb). Drop the `[ -x .substrate/checkpoint.sh ]` guard.
- `cmd_restructure` (line 400): `exec substrate-engine restructure "$@"` (P4a verb).
- `cmd baseline` (lines 401-413): already builds args and execs `.substrate/gate.sh` → exec `substrate-engine gate "${args[@]}"`.
- `selftest`/`audit`/`report` (lines 418-420): `exec .substrate/<x>.sh` stays (retained wrappers, Step 6).
- `cmd_verify` (in `core/verify.sh:56`): `.substrate/gate.sh` → `substrate-engine gate`.
- `cmd_engine pin` (lines 353-380): unchanged (already calls `$bin pin emit`).

`bin/substrate` still sources `core/install-lib.sh`, `core/doctor.sh`, `core/verify.sh`, `core/maintenance.sh` — all retained. `maintenance_run` (in `core/maintenance.sh`) already delegates to `substrate-engine maintenance` via the P4b seam; its bash body is now unreachable on the go leg and becomes dead code, retained only as the bash-rollback leg. Do NOT delete `core/maintenance.sh` (bin/substrate sources it).

### Step 4 — Re-render `.substrate/` to the P5 layout: rewrite `vendor_core()`

`bin/substrate` `vendor_core()` (lines 78-130) currently copies 24 core scripts + hooks + checks + profiles. Rewrite it to emit the post-P5a layout ONLY:

Retained (copied from `core/`):
- `gate-lib.sh` (resolution 5 — survives forever; sourced by every check).
- `selftest.sh`, `audit.sh`, `report.sh` (retained bash wrappers, edited Step 6).
- `gitleaks-deep.sh`, `gitleaks-lib.sh`, `receipt-lib.sh`, `push-gate.sh`, `gated-push.sh` (the five retained wrappers per Decided section; they already delegate to engine verbs via P2 seams).
- `install-jj.sh`, `install-gitleaks.sh` (external-dep installers, not engine — keep).
- `engine-shim.sh` (kept: retained bash wrappers and the kit rollback path source it).
- `checks.d/` (flattened from `core/checks.d/` + profile `checks.d/` + repo-local `checks.d/` — unchanged behavior).
- `profiles/<name>/` (full dir — fixtures + templates; selftest/45-contract-drift/profile checks read them).
- `langmap.json` (built by `build_langmap`, unchanged).
- `VERSION`, `engine.json` (copy from repo root), `vendor.json` (provenance).

DELETED from the vendor list (no longer copied into `.substrate/`) — engine verbs only:
- `gate.sh`, `checkpoint.sh`, `restructure.sh`, `maintenance.sh`, `maintenance-cli.sh`, `maintenance-lib.sh`, `maintenance-receipt.sh`, `maintenance-sync.sh`, `maintenance-transaction.sh`, `check-comments.sh`, `comment-ratchet.sh`, `hooks/*.sh` (all 7).

As an exception: `core/maintenance.sh` (the kit-side delegator `bin/substrate` sources) is RETAINED in `core/` but NOT vendored into `.substrate/` — rewrite it as a thin `exec substrate-engine maintenance "$@"` delegator (and drop its `source` of maintenance-lib/cli/receipt/sync/transaction), so those four become orphans and are deleted from `core/` (Step 5) while `maintenance.sh` survives as the launcher side.

`install_hooks_config` now writes the engine-form registrations (Step 2). `install_recipe` wires the justfile/Makefile gate target to `substrate-engine gate` instead of `.substrate/gate.sh`. `install_vcs_hooks` installs git hooks: the pre-commit hook body calls `.substrate/hooks/changed-files-scan.sh` (DELETED) → rewrite to `substrate-engine hook changed-files-scan`; the pre-push hook body calls `.substrate/push-gate.sh` (RETAINED wrapper) → leave in place, edit only its internal engine refs per Step 6. `wire_jj_runtime` jj push alias calls `.substrate/gated-push.sh` (RETAINED) → same leave-in-place + Step 6 edit.

Edge: a repo re-bootstrapping from an old (pre-P5a) `.substrate/` must end at the new layout. `vendor_core`'s atomic staging swap already replaces the whole dir, so the new layout replaces the old cleanly. No migration shim needed.

### Step 5 — Delete `core/*.sh` engine sources and the duplication-tax checks

Kit-side deletions (in the same cutover maintenance commit):
- Delete engine-body sources (logic now solely in the binary): `core/gate.sh`, `core/check-comments.sh`, `core/comment-ratchet.sh`, `core/checkpoint.sh`, `core/restructure.sh`, `core/maintenance-lib.sh`, `core/maintenance-cli.sh`, `core/maintenance-receipt.sh`, `core/maintenance-sync.sh`, `core/maintenance-transaction.sh`, `core/hooks/*.sh` (all 7 — engine owns `hook` dispatch). `gate-lib.sh` does not source `check-comments`/`comment-ratchet` (confirmed self-contained); deleting them leaves no dangling reference.
- RETAIN in `core/`: `install-lib.sh`, `install-assets.sh`, `vendor-source.sh`, `user-harness.sh`, `doctor.sh`, `verify.sh`, `maintenance.sh` (rewritten thin delegator), `engine-shim.sh`, `substrate-launch.sh`, `claude-hooks.json`, `claude-hooks-user.json`, `selftest.sh`, `audit.sh`, `report.sh`, `gate-lib.sh` (resolution 5), `receipt-lib.sh`, `push-gate.sh`, `gated-push.sh`, `gitleaks-lib.sh`, `gitleaks-deep.sh` (the five retained wrappers), `install-jj.sh`, `install-gitleaks.sh`, the `core/omp/` tree, `core/checks.d/` (source of retained check scripts), `core/ci/`, `core/jj-workflow.md`.
- Delete the duplication-tax checks `checks.d/80-vendor-drift.sh` and `checks.d/81-harness-parity.sh` from the repo-root `checks.d/`. Re-vendoring copies repo-root `checks.d/` → `.substrate/checks.d/`, so they drop from both. Their coverage is INHERITED by the transitional check (Step 8) + `82-check-registry.sh`.
- Regenerate `internal/gate/registry_gen.go` (`just generate-registry`) after `checks.d/` loses 80/81.

### Step 6 — Edit retained bash wrappers (selftest/audit/report/verify/push-gate/gated-push/gitleaks-deep)

For each retained wrapper, replace references to deleted `.substrate/*.sh`/`core/*.sh` with engine-verb calls:
- `core/selftest.sh` (L46-49, 129-138): line 46 `export SUBSTRATE_ENGINE=bash` and line 47 `GATE=.substrate/gate.sh`. Rewrite: drop the `export SUBSTRATE_ENGINE=bash`, set `GATE=substrate-engine gate`. Update the corrupt-langmap assertion (L131-133 expecting rc=2) to match the engine's infra-error contract (rc=3 for a read failure — confirm by running `substrate-engine gate` against a garbage langmap first). `.substrate/checks.d/*.sh`, `.substrate/profiles/*/profile.json`, `.substrate/langmap.json` stay (retained).
- `core/audit.sh`: read it to find any `.substrate/gate.sh` references; replace with `substrate-engine gate`. `test/audit-test.sh` cp's the edited audit.sh into a minimal `.substrate/` — audit.sh must resolve `substrate-engine` via PATH (fixture provides it).
- `core/report.sh`: scout confirmed no gate references — no edit. Re-confirm by reading.
- `core/verify.sh:56`: `.substrate/gate.sh` → `substrate-engine gate`.
- `core/push-gate.sh`, `core/gated-push.sh`, `core/gitleaks-deep.sh`, `core/gitleaks-lib.sh` (RETAINED): edit to call `substrate-engine receipt matches`/`gate`/`gitleaks-deep-key`. They already carry P2 `_substrate_engine_delegate` seams — verify those delegate correctly and no reference to a DELETED `.substrate/*.sh` remains. `push-gate.sh` calling `receipt-lib.sh` is fine (both retained). Keep vendored into `.substrate/`.

### Step 7 — Update the user-level launcher and the omp extension's `.substrate/` refs

- `core/substrate-launch.sh`: the upward walk execs `$dir/.substrate/hooks/$hook` (deleted). Rewrite to resolve the repo root, then exec `substrate-engine hook <name> [args]` with the discovered repo as cwd. `project_hook_registered` (line 40) updated to recognize the engine-form registration (`substrate-engine hook <name>`) so stand-down works — A16's matcher covers BOTH forms.
- `test/user-harness-test.sh`: update stand-down assertions to engine-form.
- `core/omp/substrate-quality.ts`, `transactions.ts`: replace `.substrate/push-gate.sh` (retained, no change needed for the reference) and `.substrate/hooks/changed-files-scan.sh` (DELETED → migrate to `substrate-engine hook changed-files-scan`). TS compute layer UNCHANGED.

### Step 8 — Transitional engine↔TS parity successor check (replaces 81)

Create `checks.d/81-engine-ts-parity.sh` (reuses the `81-` sort slot). Enforces: every Claude hook identity (`core/claude-hooks.json`) has a corresponding engine `hook` dispatch entry (`internal/hook/dispatch.go`) AND an omp TS `// mirrors:` comment in `substrate-quality.ts`. Uses grep (no engine spawn in the gate). Note: `comment-ratchet.sh` is the 8th dispatch entry but has NO `// mirrors:` in the TS — the check flags this asymmetry as a P5b-acknowledged gap. Deleted when P5b shims the TS compute layer. Satisfies criterion 4 (old `81-harness-parity.sh` is gone; successor is a different file).

### Step 9 — Migrate tests that reference deleted `.substrate/*.sh` (A13)

Tests calling DELETED paths migrate to engine verbs via the test-fixture binary. Migration per file:
- `test/receipt-test.sh`: `core/receipt-lib.sh` RETAINED — no rewrite. If the test calls `.substrate/gate.sh` to produce receipts, replace with `substrate-engine gate`.
- `test/bootstrap-test.sh`: L52 `[ -x .substrate/gate.sh ]` → assert ABSENT (or `substrate-engine gate` exits green). L129/L53 untouched (retained files).
- `test/audit-test.sh`: `cp core/audit.sh` still works; fixture must put `substrate-engine` on PATH.
- `test/restructure-test.sh`, `test/jj-hooks-test.sh`: `.substrate/restructure.sh`/`.substrate/hooks/enforce-jj.sh` (deleted) → engine verbs.
- `test/vcs-hooks-test.sh`, `test/maintenance-*.sh`: push-gate/gated-push retained (no edit); `.substrate/maintenance.sh` deleted → engine verb; `.substrate/hooks/changed-files-scan.sh` deleted → engine verb.
- Scratch-repo fixtures produce P5a layout automatically once `vendor_core` rewritten. Exact set needing edits found by: `grep -r '\.substrate/(gate|checkpoint|restructure|maintenance|maintenance-lib|maintenance-cli|maintenance-receipt|maintenance-sync|maintenance-transaction|check-comments|comment-ratchet)\.sh' test/` and `grep -r '\.substrate/hooks/' test/`.
- P4b-deferred harness path/identity bugs fixed in the same pass.

### Step 10 — CI workflow migration + cutover/rollback rehearsal (A30)

- `gate` job: add Go setup + `go build` step; change `Run gate: .substrate/gate.sh` → `Run gate: substrate-engine gate`.
- DELETE `gate-parity` job (bash leg unrunnable — `.substrate/gate.sh` gone, `core/gate.sh` gone). REPLACE with `cutover-parity` job: 2 checkouts (P5a parent revision + current), run OLD `.substrate/gate.sh` against shared fixture on parent revision, run `substrate-engine gate` on current, diff findings + assert identical exit codes.
- `hook-parity` job: update `ab-hooks-test.sh`/`engine-rollback-test.sh` per Step 9 (hooks go-only post-P5a; bash leg uses pre-P5a checkout or is pinned go-only).
- `substrate-report.yml`: `.substrate/report.sh` retained — no change.
- `82-check-registry.sh` and `81-engine-ts-parity.sh` use grep form — no binary needed.

### Step 11 — Receipt recipe change (resolution 7)

Edit `internal/receipt` fingerprint inputs: stop hashing deleted vendored engine files; hash the binary pin (`engine.json` sha256) + `.substrate/gate-lib.sh` + `.substrate/checks.d/` contents instead. Read `internal/receipt` recipe v2 to find the vendored-tree hashing call site and replace its input set. Receipts invalidate once on the cutover commit (one extra gate run, self-healing).

### Step 12 — Doctor attestation (A14)

Doctor already attests the engine pin. P5a: verify doctor's `.substrate/engine.json` checks still pass; remove any langmap-freshness assertion against deleted engine files. Dev-build `0.0.0-*` + `SUBSTRATE_ENGINE_BIN` warnings already implemented (P2).

### Step 13 — Plan bookkeeping

This file is `.pi/plans/go-rewrite-p5a.md`. Flip parent plan P5 section to note P5a active. On completion: `state: committed`, supersede P4b.

## Critical files & anchors
- `bin/substrate` (`cmd_gate` L330, `cmd_checkpoint`/`cmd_restructure` L399-400, `vendor_core` L78-130) — launcher commands and vendor renderer rewritten.
- `core/install-lib.sh` (`merge_hook_groups` L68-88, `install_hooks_config` L171, `install_vcs_hooks` L219, `install_recipe` L302) — registration merge regex + VCS-hook bodies + recipe wiring.
- `core/claude-hooks.json` — registration template rewritten to engine-form.
- `internal/receipt` (recipe v2) — fingerprint input set changed. `internal/gate/registry_gen.go` — regenerated after 80/81 deletion.
- `core/substrate-launch.sh` (`project_hook_registered` L40, upward walk L60-87) — engine-form stand-down.

## Verification

Working directory: `~/git/substrate`, `SUBSTRATE_VENDOR_FROM_WORKTREE=1`, engine built via `just engine`, `export PATH="$PWD/build:$PATH"`.

1. **Issue acceptance criteria:**
   - `grep -q '"version"' .substrate/engine.json && grep -q '"binary_sha256"' .substrate/engine.json` → 0.
   - `! test -e .substrate/gate.sh && ! test -e .substrate/checkpoint.sh && ! test -e .substrate/hooks/agent-lifecycle.sh` → 0.
   - `! grep -q ".substrate/hooks/" .claude/settings.json` → 0.
   - `! test -e checks.d/80-vendor-drift.sh && ! test -e checks.d/81-harness-parity.sh` → 0.
2. **Gate green on go leg:** `substrate-engine gate` → exit 0.
3. **Hook parity:** `bash test/ab-hooks-test.sh` green.
4. **Cutover/rollback rehearsal:** `cutover-parity` CI job or manual `git worktree add` comparison.
5. **Maintenance transaction:** `substrate bootstrap --checkpoint --message 'feat(engine): P5a cutover'` → exit 0.
6. **Re-bootstrap:** in scratch repo, `substrate update --apply` replaces old `.substrate/` with P5a layout.
7. **Battery:** `just battery` green (~86s serial).

## Acceptance

- [ ] engine pinned :: bash -c 'grep -q "\"version\"" .substrate/engine.json && grep -q "\"binary_sha256\"" .substrate/engine.json'
- [ ] vendored bash engine deleted :: bash -c '! test -e .substrate/gate.sh && ! test -e .substrate/checkpoint.sh && ! test -e .substrate/hooks/agent-lifecycle.sh'
- [ ] hook registrations no longer spawn per-hook bash :: bash -c '! grep -q ".substrate/hooks/" .claude/settings.json'
- [ ] duplication-tax checks retired :: bash -c '! test -e checks.d/80-vendor-drift.sh && ! test -e checks.d/81-harness-parity.sh'
- [ ] gate green on go leg :: just engine && PATH="$PWD/build:$PATH" substrate-engine gate
- [ ] hook parity green :: bash test/ab-hooks-test.sh
- [ ] cutover parity CI :: grep cutover-parity .github/workflows/substrate-gate.yml
- [ ] maintenance transaction performs cutover :: SUBSTRATE_VENDOR_FROM_WORKTREE=1 bin/substrate bootstrap --checkpoint --message 'feat(engine): P5a cutover'
- [ ] battery green :: just battery

## Assumptions & contingencies

- **Resolved:** flag grammar complete, exit 1 for findings, exit 3 infra, exit 2 usage.
- **Resolved:** push-gate/gated-push/gitleaks/receipt-lib retained as wrappers.
- **Verify at implement:** `grep -rn '\.substrate/' core/omp/` for extra omp refs; `push-gate.sh` retained so stays, only `hooks/changed-files-scan.sh` DELETED → migrate to engine verb.
- **Gate self-hosting:** `cutover-parity` replaces `gate-parity` (Step 10). Single revert restores bash gate (resolution 9).
- **Check discovery:** `DiscoverChecks` reads `core/checks.d/` then `.substrate/checks.d/`. 80/81 live in repo-root `checks.d/`, not `core/checks.d/`. Re-vendor + regen registry after deleting.
- **Hook bash rollback (A43):** `SUBSTRATE_ENGINE=bash` has no in-tree hook leg post-P5a; revert is single-revert. `test/engine-rollback-test.sh` hooks go-only or checkout pre-P5a revision. If in-tree hook rollback required, defer deleting `core/hooks/*.sh` to P5b — but `.substrate/hooks/` MUST go for criterion 2.
