# Plan: OMP-first Substrate workflow
state: active

## Goal
Make a mutating OMP task mechanically converge through edit feedback, verification, a green local gate, monotonic baseline tightening, and a local jj checkpoint without the user asking for any step; keep push explicit, full-history secret scanning off the workstation hot path, maintenance advisory, and every action visibly attributable to the exact Substrate runtime that executed it. The motivating dotfiles scan took 29.88 s at 570% CPU for full history versus about 5.3 s on one core for a pending jj range that caught both the working-copy secret and an add-then-remove commit.

## Files in scope
- `bin/substrate`, `core/install-lib.sh`, `core/install-assets.sh` — symlink-safe CLI root, checkpoint/deep/status commands, managed installation and migration.
- `core/omp/substrate-quality.ts`, `substrate-profiles/kit-ts/types/pi-surface.d.ts` — one authoritative OMP extension, lifecycle guard, checkpoint tool, ownership ledger, runtime health.
- `core/checkpoint.sh` (new), `core/gate.sh`, `core/gate-lib.sh` — shared checkpoint transaction, local/deep modes, exact-state receipt, atomic tightening.
- `core/hooks/changed-files-scan.sh`, `core/hooks/protect-paths.sh` — Bash-proof governance protection and cheap edit feedback.
- `core/checks.d/50-gitleaks.sh`, `core/ci/github-gate.yml` — pending-only local scan and one CI-owned full-history scan.
- `core/report.sh`, `core/checks.d/55-report-freshness.sh`, `core/ci/github-report.yml` — non-blocking automatic local maintenance and scheduled issue.
- `core/gated-push.sh`, `core/hooks/gate-before-push.sh`, `core/claude-hooks*.json`, `core/substrate-launch.sh` — receipt-aware push and Claude parity.
- `test/agent-workflow-test.sh` (new), `test/gitleaks-scope-test.sh` (new), `test/install-path-test.sh` (new), `test/{bootstrap,user-harness,vcs-hooks,report-freshness,report-e2e,parity}-test.sh` — end-to-end firing oracles.
- `README.md`, `docs/contracts.md`, `docs/jj-workflow.md`, `guides/daily-workflow.md`, `guides/working-with-the-gate.md` — installed and daily workflow contracts.

## Contracts
- The normal loop is `edit -> verify -> substrate checkpoint -> local commit`; OMP/Claude completion cannot succeed with owned dirty changes and no green checkpoint receipt.
- The agent supplies a Conventional Commit message at logical boundaries; the checkpoint command runs the gate, tightens, path-scoped commits, verifies the result, and never pushes.
- Automatic commit is allowed only for paths proven clean at task start and mutated by that agent; overlap, pre-existing dirt, unobserved changes, or concurrent drift refuses safely with exact paths.
- Direct agent `jj commit` routes to the checkpoint command; Bash writes to the baseline, vendored engine, contracts, or governance are denied except narrow Substrate-owned maintenance commands, with post-tool tamper detection as a backstop.
- Local Gitleaks scans exactly the jj working-copy commit plus commits reachable from the checkpoint/push tips but not remote refs in one bounded process; the Git path receives an equivalent canary-proven surface.
- Full reachable history belongs to the pinned CI action, explicit `gate --deep`, and release checks. A local deep-pass cache keys all reachable ref tips, Gitleaks version, effective config/ignore files, and engine version; any uncertainty rescans.
- Existing baselines tighten automatically only after a green run, component-wise, through a same-directory atomic replace. Initial debt adoption and every regression acceptance remain explicit and visible.
- A same-session gate receipt is reusable only for the exact post-checkpoint tree and gate-input fingerprint; any file, ref, config, baseline, engine, or invoked-tool change invalidates it.
- `substrate-report.md` remains ignored advisory state, refreshes automatically when due, and never turns a deterministic code gate red; CI retains the durable scheduled issue.
- The user-scoped OMP extension is authoritative; managed repo-local legacy copies migrate away. Doctor and `/substrate status` report the actual loaded path, content hash, engine version, repo root, last scan, checkpoint, and receipt.
- OMP-first is not OMP-only: Claude stop hooks, Git hooks, the jj push alias, and CI consume the same checkpoint/gate contract. Push is always gated and always user-initiated.

## Pattern to copy
- `core/hooks/changed-files-scan.sh` — resolve the real repo, fingerprint exact inputs, memoize passes only, fail closed on infrastructure, and return actionable blocking text without hiding detector output.

## Non-goals
- No automatic push, remote bookmark publication, initial baseline creation, or hidden `--accept-regression`.
- No commit containing pre-existing or ambiguously owned work; no prompt-only fallback presented as enforcement.
- No profile detector, finding threshold, unscanned ledger, or existing baseline ceiling is relaxed.
- No rewrite of `.pi/plans/completion.md`; it remains frozen historical evidence.

## Acceptance
- [ ] installed CLI resolves its support root and doctor reports the actually loaded OMP path and expected content hash :: test/install-path-test.sh && test/user-harness-test.sh
- [ ] successful mutating tasks gate, tighten, checkpoint, and stop cleanly while red or forgotten checkpoints re-enter work :: test/agent-workflow-test.sh
- [ ] dirty overlap, concurrent drift, direct jj commit, and Bash governance tampering fail without absorbing user work :: test/agent-workflow-test.sh
- [ ] pending Gitleaks handles added, modified, renamed, deleted, working-copy, and add-then-remove secrets in Git and jj with one local invocation :: test/gitleaks-scope-test.sh
- [ ] deep-scan ownership and cache invalidation preserve full-history coverage without duplicate CI scans :: test/gitleaks-scope-test.sh
- [ ] automatic tightening is atomic and monotonic while initial debt and regressions remain explicit :: test/vcs-hooks-test.sh
- [ ] report maintenance refreshes automatically and never blocks the code gate :: test/report-freshness-test.sh && test/report-e2e.sh
- [ ] push stays explicit, rejects stale receipts, and remains gated outside OMP :: test/vcs-hooks-test.sh
- [ ] Claude and OMP lifecycle semantics remain mechanically equivalent :: test/parity-test.sh
- [ ] negative battery green :: bin/substrate selftest
- [ ] gate green :: substrate gate
