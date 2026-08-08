# Plan: Go engine rewrite — P3a (bash-leg remediation + oracle freeze)

state: committed (became `.pi/plans/go-rewrite-p3a.md` at W0).
Parent: `.pi/plans/go-rewrite.md` (resolutions 1–12, amendments A1–A40). Sibling: `.pi/plans/go-rewrite-p3.md` (the full P3 design; P3a = its W0–W3).

## Context

The bash gate engine is being ported to a static Go binary across phases P0–P5. P0/P1/P2 are
committed. P3 (gate-runner bookkeeping in Go) is `state: draft` and **not started**:
`internal/gate/` is absent, all seven new P3 suites are missing, `SUBSTRATE_METRICS_OUT` is absent.

The P3 design (`.pi/plans/go-rewrite-p3.md`) names **eight A31 (data-destroying / guard-disabling)
defects** inside the gate's blast radius and rules the phase ORACLE-FIRST and BASH-FIRST: the
failing tests and bash fixes must land before any Go runner exists. **The issue-14 ratchet-reason
work landed *after* P3 was drafted and moved the ground** — verified this session, it fixed C2's
primary keyed-grammar bug (`ratchet()` now uses `${line%%: *}` at `core/gate.sh:270`, matching the
full structured key in `write_baseline:349,352`) and added an `=`-aware protect-command regex
(`internal/policy/protect_command.go:22`). The remaining defects are still live (verified):
C3b×2 (plain-path floor + direction loss, `write_baseline:363-365`), C4 (no 0x1F guard in
`build_claims`), C5 (scoped-inventory fail-open, `gate.sh:64-68`), C8 (empty `checks.d` → all-green,
`gate.sh:187`), C9a (colon-paths dropped, `10-comments.sh:25`).

**This plan covers P3a only** — W0–W3: re-validate the defect inventory, land the bash fixes and the
oracle/metrics-sink infrastructure, and make inventory NUL-safe. The Go runner, native checks, the
delegation seam, and the C13 probe moves (P3's W4–W9, including the Go-side C9c/C9d classifier
fixes) are a **separate P3b plan** that lands once P3a is green and gives the port a proven bash
oracle to be measured against. End state of P3a: every live A31 defect fixed on the bash leg with a
RED-first-turned-green oracle, the metrics JSONL witnessed against the runner, inventory NUL-safe,
repo green, `.pi/plans/go-rewrite-p3a.md` committed and `go-rewrite-p3.md` left as the P3b basis.

## Approach

Ordered; the repo is green between every item. Vendored `.substrate/` changes need the two-commit
sequence in Operational Notes #1 (the maintenance transaction is the only authorised writer for
`.substrate/**`; `protect-paths.sh` hard-blocks direct edits).

### W0 — plan only
Land `.pi/plans/go-rewrite-p3a.md` (this file's content) with `state: active`, `parent:` and
`issue:` pointers, and fold A39/A40 into `.pi/plans/go-rewrite.md`'s amendment list (A33–A38 are
already present). Update `go-rewrite-p3.md`'s Goal to note P3a splits off W0–W3 and it becomes the
P3b basis; do NOT flip its state.
Merge gate: `bash .substrate/gate.sh` green. Markdown only.

### W1 — metrics sink + oracle infrastructure + A31 re-validation (bash-only, RED-first)
1. **Metrics sink first.** In `core/gate.sh`, add `SUBSTRATE_METRICS_OUT` mirroring the staged-mktemp-
   then-`mv -f`-with-umask-derived-chmod idiom already used for `SUBSTRATE_CLAIMS_OUT`
   (`gate.sh:128-138`): after `run_checks` concatenates all shards into `$METRICS` and before
   `ratchet` is called (between the `run_checks` and `ratchet` calls at `gate.sh:426-427`), if the
   var is set, stage-copy `$METRICS` to it with `chmod "$(printf '%04o' "$((0666 & ~0$(umask)))")"`
   and `mv -f`. Immediately `cmp -s` its output against `test/golden/metrics.jsonl`. **If they
   differ, BLOCK** — that is a pre-existing defect the sink uncovered; do not recapture and move on
   (C10). Re-vendor `.substrate/gate.sh`.
2. **A33 oracle-infra edits (P3a-relevant subset):**
   - `test/lib/golden-fixture.sh` `golden_run_gate`: export `SUBSTRATE_ENGINE="${GOLDEN_ENGINE:-bash}"`
     (today an ambient `substrate-engine` on PATH silently captures/verifies frozen vectors on the
     GO leg), `SUBSTRATE_METRICS_OUT`, and pin `SUBSTRATE_GATE_JOBS=4`; `golden_write_manifest`
     records the engine identity.
   - `test/golden/manifest.json`: add the engine-identity field ONLY; prove vector BYTES unmoved
     (`cmp` against a pre-edit copy).
   - `test/capture-golden-vectors.sh`: follow the same three exports.
   - `test/ab-hooks-test.sh`: replace its open-coded `go build` (no `-ldflags`) with
     `engine_build` (`test/lib/engine-fixture.sh:27`) so the engine reports a real version and P2's
     B4 attestation is non-vacuous.
   - `test/claims-table-test.sh`: add an outer `bash|go` loop plus `cmp -s` of the two tables (today
     single-leg, verdicts-only — the acceptance line it backs would be false otherwise).
   - `core/selftest.sh`: add a leg sweep.
   - `test/matrix.sh` and `test/hostile-home.sh`: pin `SUBSTRATE_ENGINE=bash` so profile-matrix leg
     selection stops being ambient.
3. **New P3a suites (A33 item 12 subset — the bash-fixable ones):**
   `test/gate-inventory-guard-test.sh` (C5), `test/claims-injectivity-test.sh` (C4), and new
   `test/baseline-test.sh` scenarios for C3b floor/direction survival + C2 Route (c) + tie-break +
   null-metric + keyed-accept, plus a colon-bearing-path fixture and an adversarial-comment-text
   fixture for C9a. (`gate-ab`, `gate-env-probe`, `gate-scheduler`, `check-registry` suites are P3b.)
4. **Re-validate every candidate defect RED for the right reason.** For each, write the assertion,
   then prove it red by deliberately reverting its future fix. Confirmed-live set (this session):
   C3b×2, C4, C5, C8, C9a. **C2 primary is OBSOLETE** — assert it GREEN (keyed
   `--accept-regression=probe:alpha` matches and persists) and add a one-line note in the plan that
   issue-14 closed it; do not re-fix. Re-confirm C2 Route (c) (bare `--accept-regression` with
   `--tighten`): if still a one-shot bypass, it joins the W2 fix set; if issue-14 closed it too,
   mark obsolete.
Merge gate: the metrics `cmp` green OR blocking-with-explanation; every other new assertion
demonstrably red. Run only the new suites + `bash .substrate/gate.sh` — no battery, no audit (A39).

### W2 — the live A31 bash fixes, one commit each (A34), plus two determinism pins
Each fix: edit `core/`, run
`bin/substrate update --apply --force --checkpoint --message '<=50 chars>'` (authorised
`.substrate/**` writer), then `substrate_checkpoint` the `core/` change. Each is a commit PAIR and
independently revertible. Per-commit merge gate = only the suite(s) that fix touches (A39). ONCE at
the end of W2, the full serial battery (`just battery`) — not once per fix.

- **C5 — scoped-inventory fail-open** (`core/gate.sh:64-68`). The scoped branch `cp "$SUBSTRATE_FILE_LIST" "$INVENTORY"; return 0` discards `cp`'s status and has no non-empty guard, so a missing target ⇒ empty inventory ⇒ `[ok] gate: all checks passed`, and with `--tighten` the baseline is destroyed. Fix (scoped branch only): `cp … || die_infra "scoped inventory: cannot read SUBSTRATE_FILE_LIST ($SUBSTRATE_FILE_LIST) …"`; then `[ -s "$INVENTORY" ] || die_infra "scoped inventory: SUBSTRATE_FILE_LIST is empty — a scoped gate over nothing cannot pass blind"` (rc 3; messages DISTINCT from `:83`'s, which actively misleads on a scoped run). Everything else stays verbatim — no `[ -f ]` filter, no sort, no dedup (`test/golden/claims.0x1f` and the phantom-path coverage depend on that). Suite: `test/gate-inventory-guard-test.sh` — `SUBSTRATE_FILE_LIST=/dev/null bash .substrate/gate.sh` exits 3, not 0.
- **C8 — empty `checks.d` reads all-green** (`core/gate.sh:187`). The `for chk in …/*.sh` loop with `[ -f "$chk" ] || continue` makes zero checks indistinguishable from all-green. Fix: before the loop, set a `found` flag on the first real file and `die_infra "no checks in $SUBSTRATE_DIR/checks.d — a gate with zero checks cannot pass blind"` (rc 3) if none. Suite: a scratch repo with an empty/absent `checks.d` must exit 3, not 0.
- **C4 — 0x1F CLAIMS forgery** (`core/gate.sh:88-139`, the inventory loop emitting `printf '%s\t%s\n' "$f" "$entry"`). A pathname holding a literal 0x1F (US) byte — representable in bash, unlike NUL — forges a CLAIMS row. Fix: a `case "$f" in *$'\x1f'*) …` guard before the emit, `die_infra` rc 3, offending bytes rendered as `\xNN` by a helper defined ONCE (NOT `printf %q` — that is the LC_CTYPE-dependent construct P2 removed). NUL is dropped from the bash guard (unrepresentable; `$'\0'` is empty so `*$'\0'*` degenerates to `**` and rejects every path). TAB keeps its current `claims table build failed` behaviour (registered under A32, A38). The row format, `test/golden/claims.0x1f`, and the `gate-lib.sh` reader are BYTE-UNCHANGED. Suite: `test/claims-injectivity-test.sh` — a 0x1F path ⇒ rc 3, no forged CLAIMS row.
- **C9a — colon-paths dropped from the comment ratchet** (`core/checks.d/10-comments.sh:25`). `grep -oE '^[^:]+:[0-9]+: ' | cut -d: -f1` cannot parse a finding for a path containing a colon, so no `comments:<path>` metric is emitted and the file is never enforced. Fix: replace the grep+cut parse with a non-greedy jq capture matching the rendered report line, `capture("^(?<f>.+?):[0-9]+: [a-z-]+: ")` (the plan's measured-correct form; greedy `.+` fabricates paths when comment text itself contains `:<digits>: <rule>: `). If the adversarial-comment-text fixture still breaks byte-agreement between the parsed path and the real path, fall back to a NUL-framed `path\tcount` side channel emitted by `core/check-comments.sh` (human report stays byte-identical). Suite: `test/baseline-test.sh` — a `src/a:b.go` finding emits and enforces `comments:src/a:b.go`.
- **C3b — plain-path floor + direction loss** (`core/gate.sh:336-366`). The plain `--update-baseline` path (`write_baseline:363-365`) is a total replacement `{metrics: $m, direction: $dir}` with no `$kept` clause, so any baseline key not emitted this run vanishes — including higher-is-better floors and their direction (a hi metric that stops emitting loses its `hi` and is re-read as `lo`). Fix: delete the total-replacement `else` branch; route bare `--update-baseline` through the SAME merge as `--tighten` (the `:346-361` block) with an empty `$accepted` list, so unemitted hi-floors and their direction are preserved via `$kept`. Bare `--update-baseline` on a first (absent) baseline still just writes current metrics (the merge reduces to current when `$old_m` is absent). Suite: `test/baseline-test.sh` — disable a check with a hi-floor, `--update-baseline`, the floor + its `hi` direction survive; cross-leg `cmp -s` of `substrate-baseline.json`.
- **C2 Route (c) — only if W1 re-validates it live.** If bare `--accept-regression` + `--tighten` still records an `accepted` entry without moving the floor (one-shot bypass), fix `ratchet()`/`write_baseline` so bare `--accept-regression` records current values, not a silent no-op. Own commit, own scenario. If obsolete, mark and skip.
- **Determinism pin 1 — `LC_ALL=C` on check discovery** (`core/gate.sh:187`). The glob `"$SUBSTRATE_DIR"/checks.d/*.sh` is collated by `LC_COLLATE`, not byte-sorted (A35 [was wrong]). Pin `LC_ALL=C` on the discovery so both legs are deterministic. Legal — gate.sh is not byte-frozen.
- **Determinism pin 2 — `RUN_DIR` in `cleanup()`** (`core/gate.sh:61`). The EXIT trap currently removes only `$INVENTORY $METRICS $CLAIMS $CLAIMS.raw`; add `"$RUN_DIR"` so an interrupted run cannot leak the per-check tmpdir. (The Go-side signal obligation — kill the check process group, remove temps, re-raise so the process still dies BY the signal preserving 130 — is P3b.)

### W3 — NUL-safe inventory listing on both backends (own commit)
`core/gate.sh:75-82` lists via `jj file list` / `git ls-files` (newline-delimited), so a pathname
containing a newline is split into two phantom inventory rows. Fix: `git ls-files -z` and
`jj file list -T 'path ++ "\0"'`, with `build_inventory` rewritten to `while IFS= read -r -d ''` fed
by process substitution; the `[ -f "$f" ]` filter and the rest stay verbatim. **`-z` fixes QUOTING,
not ORDER** — the two backends' orders measurably differ on this repo (git byte-sorts so
`core/omp/substrate-quality.ts` precedes `core/omp/substrate-quality/`; jj groups the directory
first). **Decision (Ruling 1): freeze per-backend order** — do NOT byte-sort; reproduce each
backend's native order bug-for-bug (byte-sorting both is a NEW A31-class divergence that changes
05's finding order and 30's tie-break file in real repos, forbidden under A31). Register the
per-backend order difference as a known, measured divergence in the test that covers it.
Merge gate: identical inventory SET under both backends (`comm` after sort), NOT identical order.

## Critical files & anchors
- `core/gate.sh` — `build_inventory` (64-84, C5+W3), `build_claims` (88-139, C4), the scheduler loop
  (176-220, untouched in P3a — frozen FIFO window, C11/A35), `ratchet()` (225-334, C2 Route c),
  `write_baseline` (336-420, C3b), `cleanup`/EXIT trap (61-62, RUN_DIR). Reason: every P3a fix lands
  here; re-read before each edit (issue-14 moved line numbers).
- `core/checks.d/10-comments.sh:25` — the grep+cut parse (C9a). Reason: the one check-side fix.
- `core/check-comments.sh` — C9a NUL-framed side-channel fallback target; `core/comment-ratchet.sh:25`
  invokes it as the hook's bash rollback leg (must stay reachable, B1).
- `test/lib/golden-fixture.sh` + `test/lib/engine-fixture.sh:27` (`engine_build`) — oracle infra
  every new suite must use (A1/A25 self-build, unique dirs, real `-ldflags` version).
- `test/golden/metrics.jsonl` + `test/golden/claims.0x1f` — the frozen vectors the metrics sink `cmp`s
  and the byte-unchanged CLAIMS format C4 must not touch.

## Verification
- **Metrics sink (C10):** from repo root, `SUBSTRATE_METRICS_OUT=$(mktemp) bash .substrate/gate.sh`;
  `cmp -s "$SUBSTRATE_METRICS_OUT" test/golden/metrics.jsonl && echo OK`. Green or BLOCK with
  explanation — never recapture silently.
- **Each A31 fix:** its named suite, run as `bash test/<suite>.sh`, must be GREEN after the fix and
  was proven RED before it (revert + rerun). Specifically: `test/gate-inventory-guard-test.sh` (C5 —
  `SUBSTRATE_FILE_LIST=/dev/null bash .substrate/gate.sh` exits 3, not 0), `test/claims-injectivity-test.sh`
  (C4 — a 0x1F path ⇒ rc 3, no forged CLAIMS row), `test/baseline-test.sh` (C3b — disable a check with
  a hi-floor, `--update-baseline`, the floor + its `hi` direction survive; cross-leg `cmp -s` of
  `substrate-baseline.json`), and the C9a colon-path fixture (a `src/a:b.go` finding emits and
  enforces `comments:src/a:b.go`).
- **C2 obsolete proof:** `--accept-regression=comments:src/x.go --reason='<20+ chars>'` matches and
  persists the colon-bearing key (green, not the old truncation-to-`comments`).
- **Inventory NUL-safe (W3):** a tracked file whose name contains a newline lists as ONE row under
  both backends; `comm -3 <(git sort) <(jj sort)` empty (same SET).
- **Phase gate (once):** `just battery` (serial, A37) green; `bash .substrate/gate.sh` green; no
  `audit` run unless an acceptance oracle changed (A39). Run the battery SERIALLY — parallel runs
  contend on shared user state (A37: scratch `HOME`, `SUBSTRATE_NO_USER_HARNESS=1`, `JJ_CONFIG`).
- Exit: every oracle checked, repo green, `.pi/plans/go-rewrite-p3a.md` `state: committed`,
  `go-rewrite-p3.md` left `draft` as the P3b basis.

## Assumptions & contingencies
- **Scope (user decision, this session): P3a = W0–W3 only.** P3b (W4–W9: Go runner, natives incl.
  the Go-side C9c/C9d classifier fixes, delegation seam, C13 probe moves) is a separate plan. If, at
  W1, more than ~7 defects are live or the inventory re-validation surfaces new ones, do NOT shrink —
  extend W2 one commit per defect (A34: never quietly drop an exception).
- **Ruling 1 (inventory order): freeze per-backend** (bug-for-bug). If a consumer repo's check
  output depends on a specific cross-backend order, that is a NEW divergence to register, not a
  reason to byte-sort.
- **Ruling 2 (`.checks.disabled` as STRING substring search, `gate.sh:190` jq `index`): reproduce
  bug-for-bug** in P3a with a fixture documenting that `.checks.disabled = "zz05-x.shzz"` disables
  `05-x.sh`. Conservative (zero behavior change). If the user prefers enforcement, it becomes a 9th
  A31 exception (require array) — defer to P3b.
- **Rulings 3 (rc=70) & 4 (Go signals) & A40 (scheduler default): P3b scope.** Adopt the plan's
  recommendations there: rc=70 = `cmd.Wait()` returned a non-`*exec.ExitError`, keep wording + `ms=0`;
  Go signal handler kills the check pgroup, removes temps, re-raises (preserve 130); A40 option (a)
  — raise default `max` on both legs for the ~2× gate speedup (only observable: disabled-warning
  position). Recorded here so P3b inherits them without re-litigating.
- **C3b commit shape:** floor-loss and direction-loss share the `write_baseline` merge lines, so they
  land as one commit with two scenarios rather than two commits (A34 deviation, reason in the message).
  If they turn out cleanly separable after re-reading, split into two.
- **If the metrics `cmp` differs at W1:** that is a real pre-existing defect; BLOCK and surface it,
  do not recapture. The fix (if any) becomes its own A31-class item in W2.

## Operational notes (still true)
1. Vendored changes need two commits: `bin/substrate update --apply --force [--checkpoint --message '<=50 chars>']` first (authorised `.substrate/**` writer), then `substrate_checkpoint` for `core/` source.
2. Never `export` into the persistent shell; use `env VAR=… cmd`.
3. Byte-comparing tests use only `test/.toolchain/bin/jq` (A4); ambient `jq` may be jaq.
4. Run the suite battery SERIALLY when the result matters (A37).
5. Files written exclusively by background subagents can be missing from the ownership ledger — write through blocking calls, or re-write the final bytes once through a direct tool call before checkpointing.

## Acceptance
- [x] W0 plan landed :: bash -c 'grep -q "^state: active" .pi/plans/go-rewrite-p3a.md && grep -q "^Parent:" .pi/plans/go-rewrite-p3a.md'
- [x] W1 metrics sink verified :: bash -c 'SUBSTRATE_METRICS_OUT=$(mktemp) bash .substrate/gate.sh && cmp -s "$SUBSTRATE_METRICS_OUT" test/golden/metrics.jsonl'
- [x] W1 oracle infra landed :: bash -c 'grep -q "SUBSTRATE_ENGINE" test/lib/golden-fixture.sh && grep -q "engine" test/golden/manifest.json'
- [x] W1 all A31 defects RED :: bash test/gate-inventory-guard-test.sh && bash test/claims-injectivity-test.sh
- [x] W2 all bash fixes committed :: bash -c 'git log --oneline | grep -q "C5:" && git log --oneline | grep -q "C8:" && git log --oneline | grep -q "C4:" && git log --oneline | grep -q "C9a:" && git log --oneline | grep -q "C3b:"'
- [x] W3 inventory NUL-safe :: bash -c 'grep -q "ls-files -z" .substrate/gate.sh && grep -q "read -r -d \'\'" .substrate/gate.sh'
- [x] Phase gate: full battery green :: just battery
- [x] Repo green :: bash .substrate/gate.sh
- [x] Plan state committed :: bash -c 'grep -q "^state: committed" .pi/plans/go-rewrite-p3a.md'
