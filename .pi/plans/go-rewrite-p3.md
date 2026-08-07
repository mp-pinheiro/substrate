# Plan: Go engine rewrite — P3 (gate-runner bookkeeping in Go)
state: draft
issue: https://github.com/mp-pinheiro/substrate/issues/12
parent: .pi/plans/go-rewrite.md

## Goal
Move the gate runner's bookkeeping into the engine: preflight hand-off, inventory, CLAIMS, check spawn/scheduling/
reporting, metrics aggregation, the ratchet and baseline writes. Checks stay spawned bash. `core/gate-lib.sh` gets
ZERO byte changes — the engine feeds it. Five checks (05/15/30/40/10-comments) become native behind a registry.

Read first: `.pi/plans/go-rewrite.md` (12 resolutions, shared-artifact compat table, amendments A1–A20 + A25–A38) and
`.pi/plans/go-rewrite-p2.md` (bindings B1–B7 and its Landed section — P3 inherits its precedents). Both are
self-contained; no chat context is required.

## Method
Six parallel read-only contract extractions over the runner, ratchet, check contract, natives, consumers and oracle
layer (130 contracts, 99 hazards, 34 high, all measured), a 3-lens architecture panel reconciled by 2 judges, then a
4-lens adversarial review OF THE RESULTING PLAN that produced 66 findings, ~20 of them high. **The first draft of this
plan was wrong in six load-bearing ways** — every correction is folded below and flagged `[was wrong]` so the next
reader can see what the review bought.

**The dominant finding: bash has six live data-destroying or guard-disabling defects inside P3's blast radius.** P3 is
therefore ORACLE-FIRST and BASH-FIRST: the failing tests and the bash-leg fixes land before any Go runner exists, so
the port has something true to be measured against.

## Bindings (C1–C13; they override any looser reading of the parent plan)

**C1 — Seam shape: whole-run delegation behind a capability probe. Bash keeps preflight, and NEVER `exec`s.**
`core/gate.sh` KEEPS root resolution and its five exports (`:8-14`), the arg loop and usage/exit-2 (`:19-31`), and the
three `jq -e .` preflight gates (`:33-38`). All five existing exit-2 conditions stay emitted BY BASH on BOTH legs, so
`core/selftest.sh:116-135`'s assertions hold unchanged.

- New engine verb `capabilities`: one supported verb per line, `LC_ALL=C` order, rc 0; rc 1 on write error; never
  rc 2 of its own accord. An older binary hits `main.go`'s `default:` and returns 2 having done NO work — an
  unambiguous skew signal.
- New `core/engine-shim.sh` helper `substrate_engine_supports <feature> <verb>`. Capture status explicitly:
  `bin=$(substrate_engine_supports gate gate); rc=$?`, then branch on ALL THREE values — 0 delegate, 1 fall back to
  bash, 2 hard-fail. **[was wrong]** the first draft justified this by claiming `if bin=$(…)` "clobbers `$?`"; measured
  on bash 5.2.21, `$?` IS preserved into the `else`. The real reason is that a two-way `if` collapses rc 1 and rc 2
  into one branch, which is exactly the P2 defect where forced `go` silently answered from bash.
- **Delegation runs the engine as an ordinary FOREGROUND CHILD with inherited stdio — never the `exec` builtin, and
  never `$(...)` capture.** **[was wrong]** the first draft said `exec`; measured, `exec` replaces the process image
  and the EXIT trap never fires, so no wrapper survives to remap an exit code. Inherited stdio alone gives live
  streams and a single run.
- The engine's gate handler NEVER returns 2. Its own preflight-class refusal is sentinel rc **12** (verified free: no
  `exit 12`/`return 12` anywhere in `core/*.sh`, `cmd/`, `internal/`). The wrapper does:
  `rc=$?; [ "$rc" -eq 12 ] && exit 2; [ "$rc" -eq 2 ] && die_infra 'engine gate returned the reserved unknown-verb
  code after a successful capability probe'; exit "$rc"`.
- No `--argv0` and no `SUBSTRATE_GATE_ARGV0`: bash owns the usage string and already has the real `$0`.
- The engine resolves `SUBSTRATE_DIR`/`REPO_ROOT` from the INHERITED environment when set (always true under C1), and
  otherwise by an upward walk for `.substrate/VERSION`. Both must reproduce bash's logical (`cd -L`) spelling. W5
  invokes the engine directly, so it ships a thin harness exporting exactly C1's five variables — otherwise W5 and W8
  would test two different environments.

**C2 — `--accept-regression=<metric>` is broken; A31 exception #1 FIRES.** Measured: `ratchet()` recovers the key with
`${line%%:*}` (`core/gate.sh:240`), truncating at the FIRST colon, while `write_baseline` matches the FULL key
(`:286`). `--accept-regression=probe:alpha` never matches; every `comments:<path>` metric is unreachable by its own
name; `--accept-regression=probe` makes the ratchet green while the baseline writer persists NOTHING — a one-shot
bypass leaving the next run red. Both legs, same batch, bash first.

ONE grammar, the one `write_baseline` already uses at `:283`: `($keys | split(",") | map(select(length > 0)))`, exact
element match against the STRUCTURED key. `ratchet()`'s `${line%%:*}` and comma-fenced `case` (`:240-244`) are
DELETED; `worse` carries `{key,value,baseline}` objects and renders the display line only at print time. Every frozen
string stays byte-identical. This also closes the non-injective worse-line framing (a metric name containing `\n`
currently splits one regression into two verdicts).

Two additions the first draft missed:
- **Route (c):** `--tighten --accept-regression` (bare, no keys) takes the `elif` at `:255-257`, prints the worse
  lines, adds 0 to `FAILURES`, and then `write_baseline`'s tighten path keeps the OLD floor — a third silent one-shot
  bypass. Under the unified grammar, bare `--accept-regression` must record current values, not silently no-op.
- **Blast radius:** `core/hooks/protect-command.sh:63` and `internal/policy/protect_command.go:22` both match
  `(^|[[:space:]])(--update-baseline|--tighten|--accept-regression)([[:space:]]|$)`. Verified: the trailing context
  means `substrate baseline --accept-regression=probe:alpha` is **ALLOWED past the guard today** while the bare form
  is blocked. Making the keyed form actually work turns that hole into a live bypass of the baseline guard. The
  trailing context becomes `([[:space:]=]|$)` on BOTH legs in the same commit, with an A/B scenario.

**C3 — metric values are opaque literals; the baseline serializer is purpose-built.** jq preserves number LITERALS
(measured into the baseline: `3.0`→`3.0`, `-0`→`-0`, `1e100`→`1E+100`, `1e-7`→`1E-7`, 21-digit integers exact).
Carry `MetricRecord{Name string, RawValue []byte, Dir string}` end to end; never round-trip a value through `float64`.

- **[was wrong]** the first draft claimed `1e400` is "a Go marshal ERROR". Measured against the very package it
  mandates reusing: `internal/canonjson` marshals it as `1E+400`, and `Float64()` returns `+Inf` with a nil error —
  `internal/canonjson/value.go:22-29` deliberately ignores `strconv.ErrRange` to mirror jq. The bug-pin is therefore
  the measured behaviour (`1E+400`, `+Inf`, `[1e400,5]|min → 5`, `max → 1E+400`), not an error path.
- Add `Number.Cmp` doing DECIMAL comparison (sign, adjusted exponent, digit string): jq compares literals in decimal,
  so `999999999999999999999 < 1000000000000000000000` is TRUE though they are identical as float64. Reproduce the
  predicate's mixed arithmetic faithfully — `(b // 0) ± 1e-9` demotes the baseline side to a double, so the predicate
  is float while min/max selection is decimal.
- **jq's tie asymmetry, explicitly:** `min` returns the FIRST of equal elements, `max` the LAST, over `[old, current]`
  — a `lo` tie keeps the OLD literal, a `hi` tie keeps the CURRENT one. A naive `if cur < old` reproduces the lo rule
  and BREAKS the hi rule, churning baseline bytes on every tightening run.
- **`null` is a reachable metric value.** `jq '"nan"|tonumber'` returns `null` at rc 0, so `metric x nan` does NOT
  trip `die_infra` and appends `{"name":"x","value":null}`. jq orders `null` below every number: a null `lo` metric is
  never worse, a null `hi` metric is ALWAYS worse. `null` must sort below every number in `Cmp` and render as the
  literal `null` in both the worse line and the baseline.
- Do NOT call `canonjson.MarshalSorted` on the baseline document: measured, `write_baseline` sorts `metrics` keys but
  does NOT sort `direction`, and a document-level sort would silently reorder it. Use a purpose-built top-level
  serializer with `MarshalIndent` reproducing jq's default pretty-print (2-space, `": "` after each key, `,\n` between
  members, `{}` inline when empty, no trailing newline — the caller's `printf '%s\n'` supplies it). `MarshalIndent`
  MUST error on nesting deeper than the baseline's two levels rather than guess a shape the baseline never contains.

**C3b — two further baseline data-destruction defects; A31 exceptions #2 and #3 FIRE.** Both were measured and both
were missing from the first draft.
- The PLAIN path (`core/gate.sh:297-299`) is a TOTAL replacement with no `$kept` clause, so any baseline key the
  current run did not emit VANISHES — including higher-is-better floors and their direction. It is taken by bare
  `--update-baseline` and by bare `--accept-regression`.
- A direction flip drops the recorded direction, contradicting the published contract.
Both legs, same batch, each its own commit, each with a dual-leg baseline scenario.

**C4 — the CLAIMS 0x1F table stays byte-frozen; 0x1F-bearing paths are rejected at build time. A31 exception #4.**
The table is not injective over path bytes (`core/gate.sh:101-107`, read at `core/gate-lib.sh:93`). Unlike P2's private
framing this is a frozen shared artefact with a committed vector, so the FORMAT does not change; the guard does.
- **[was wrong]** the first draft rejected TAB, US and NUL in one bash `case`. Measured: bash strings cannot hold NUL,
  `$'\0'` expands to the empty string, and the alternative `*$'\0'*` degenerates to `**` — the guard would reject
  EVERY path. NUL is dropped from the bash guard (unrepresentable, and illegal in a pathname anyway); the Go builder
  rejects it where it is representable.
- **[was wrong]** TAB already fails closed today: `split("\t")` mis-splits, `fromjson` errors, and the runner dies
  with `claims table build failed` at rc 3. Adding a TAB clause would CHANGE an existing failure path, violating this
  plan's own non-goal. The new bash guard covers **0x1F only**; TAB keeps its current behaviour and its jq diagnostic
  is registered under A32.
- **[was wrong]** the message must not use `printf %q` — that is the exact LC_CTYPE-dependent construct P2 spent a
  session removing (B5 row H1). Offending bytes render as `\xNN`, defined once and identical on both legs.
The row format, `test/golden/claims.0x1f` and the `gate-lib.sh` reader are BYTE-UNCHANGED — no recapture.

**C5 — the scoped-inventory branch fails OPEN and `--tighten` then destroys the baseline. A31 exception #5.**
`core/gate.sh:48-51` discards `cp`'s status and returns 0; the `[ -s ]` guard at `:66` covers only the VCS branch.
Measured: a missing `SUBSTRATE_FILE_LIST` target ⇒ empty inventory ⇒ `[ok] gate: all checks passed`, and with
`--tighten` the baseline went from `{"dup_pct":0.0,"max_file_lines":54}` to `{"max_file_lines":0}` at rc 0.
`SUBSTRATE_FILE_LIST=/dev/null` is a total bypass. Both legs, same batch, scoped branch only: check `cp`'s status,
then a non-empty guard, both `die_infra` rc 3, messages deliberately DISTINCT from `:66`'s (which actively misleads on
a scoped run). Everything else stays VERBATIM — no `[ -f ]` filter, no sort, no dedup: `test/golden/claims.0x1f` and
the golden fixture's deliberate phantom-path coverage depend on that. `core/checkpoint.sh:178` unsets the variable
before gating a candidate tree so the candidate is scanned whole; unchanged.

**C6 — the spawned-check environment is PASS-THROUGH, never a whitelist.** `CI` is ambient — gate.sh never sets it,
but `gate-lib.sh:239` (`require_bin_ci`) and `:251` (`resolve_sg`) use it to choose between `die_infra` rc 3 and
warn-and-skip, so dropping it would make the gate pass blind in CI with a broken toolchain. **[was wrong]** the first
draft cited `:239,253,265` and said "ten names"; it is two call sites and NINE names plus cwd.

The engine inherits its own `environ` verbatim and OVERLAYS exactly nine names, plus `cwd = REPO_ROOT`:
`SUBSTRATE_DIR`, `REPO_ROOT`, `CONFIG`, `LANGMAP`, `BASELINE` (may not exist), `INVENTORY`, `CLAIMS`, `METRICS` (the
per-check shard, created and truncated BEFORE spawn), `SUBSTRATE_CHECK_NAME` (basename including `.sh`). It unsets
nothing and filters nothing. Frozen process facts: argv `bash <abs check path>`; stdin `/dev/null` (bash redirects an
asynchronous list's stdin when job control is off — the oracle asserts `fd0 == /dev/null` while feeding the GATE a
non-`/dev/null` stdin, so the assertion is not self-satisfying); stdout and stderr the SAME pipe inode (reproducing
`2>&1`); exec bit not required; umask inherited. `SUBSTRATE_DIR` uses `filepath.Abs` + lexical `Dir`, never
`EvalSymlinks`.

The env-probe's exemption allowlist is exactly three names — `_`, `SHLVL`, `OLDPWD` — each with a measured per-leg
delta (bash bumps `SHLVL` twice and exports `OLDPWD` as a side effect of `core/gate.sh:10`; a Go `execve` does
neither). The oracle asserts `len(allowlist) == 3` so it cannot quietly grow into a masked diff, and additionally
asserts `_CLAIMS_STATE == table` so a silent fallback to the per-file jq path cannot pass.

**C7 — the "zero test edits" claim is FALSE; the edit list is amendment A33.**

**C8 — the A11 registry.** DIGEST = sha256 of the RAW, UNNORMALISED bytes of the DISCOVERED file
`.substrate/checks.d/<name>` — the only copy a consumer has and the one that executes; `cmp -s` at
`checks.d/80-vendor-drift.sh:18` already makes bytes the identity unit. STORAGE = generated
`internal/gate/registry_gen.go` (`map[string]string`, name→digest) joined at init with hand-written `Run` bindings in
`internal/gate/natives.go`; never a JSON sidecar, which would be a presence dependency wearing a different hat.
MERGE over `sort(union(registry, discovered))`:

| case | behaviour |
|---|---|
| disabled in `substrate.json` | warn + skip, string and position unchanged |
| registry-only, `Run != nil` | run native silently — this is what makes natives survive P5's deletion |
| registry-only, `Run == nil` (20/45/50) | loud infra-fail rc 3: the executable form of "must never silently vanish" |
| discovered, digest MATCHES, `Run != nil` | run native |
| **discovered, digest MATCHES, `Run == nil`** | **spawn the FILE as bash** |
| discovered, name IS in the registry but digest DIFFERS | spawn the FILE as bash (user override), doctor-warned |
| discovered, name NOT in the registry | spawn the FILE as bash, **silently** |

**[was wrong]** the first draft omitted row 5 — the state W5 runs entirely in, since every kit check is vendored and
`Run == nil` throughout W5 — and lumped "name unknown" together with "digest differs". Verified: `.substrate/checks.d`
holds 20 checks of which only 8 come from `core/checks.d/`; the other 12 are profile and repo-local checks. Warning on
all of them would make the doctor warning worthless. Only a registry NAME with a different digest is an override.

The bash-spawn rows are load-bearing: `test/baseline-test.sh` and `test/lib/golden-fixture.sh` install ad-hoc probe
checks into `.substrate/checks.d` at runtime, and the kit ships repo-local (`80`, `81`) and per-profile checks.

**Checks.d absent or empty:** measured, bash reports `[ok] gate: all checks passed` at rc 0 — zero checks is
indistinguishable from all-green. Under the merge, the Go leg would run the five natives instead. That is a
divergence, so **A31 exception #6 fires**: both legs `die_infra` when `.substrate/checks.d` is missing or contains no
`*.sh`, before scheduling anything.

**C9 — 10-comments.** (a) `core/checks.d/10-comments.sh:25`'s `grep -oE '^[^:]+:[0-9]+: '` SILENTLY DROPS any path
containing a colon from the ratchet — the finding is reported but no `comments:<path>` metric is emitted, so it is
never enforced. **A31 exception #7.** The Go native aggregates from its OWN structured finding list keyed by path
(injective by construction).

**[was wrong]** the first draft prescribed a GREEDY `.+` for the bash replacement. Measured: on a report line whose
comment TEXT contains `see upstream bug report.c:12: warn: broken`, greedy `.+` attributes the finding to
`src/note.sh:7: narration: # see upstream bug report.c` — a fabricated path. The bash leg uses the NON-GREEDY
`capture("^(?<f>.+?):[0-9]+: [a-z-]+: ")`, measured correct on both inputs. It remains a HEURISTIC over rendered text
while Go parses structure, so W1 lands an adversarial fixture whose comment text itself contains
`:<digits>: <rule>: ` and the two legs must still agree; if they cannot, the bash leg gains a NUL-framed side channel
from `check-comments.sh` and the human report stays byte-identical.

(b) The same `sort` runs under the AMBIENT locale and its order becomes the byte-frozen metrics JSONL key order
(measured to differ between `LC_ALL=C` and `en_US.UTF-8`). The jq `group_by` rewrite removes the shell sort entirely.
(c) `internal/comments`' prose-block counter requires an ASCII alphanumeric while bash uses locale-aware
`[[:alnum:]]`, so Go MISSES findings bash reports on non-ASCII prose (measured: bash rc 1 `prose-block`, Go rc 0).
**A31 exception #8** — it is a guard weakening, gets its own commit and A/B scenario per A34, and it changes the HOOK
path too, so files that pass the write-time ratchet today may start failing under a UTF-8 locale.
(d) **The runner owns file selection.** The runner computes the scan list (CLAIMS table ∩ NOT unscanned, exempt
included) and the classifier consumes it VERBATIM — no `EntryFor`, no `ScopeAllows`, no `os.Stat` re-filter.
`internal/comments/scanner.go:69-83` currently re-derives all three, which is bash's NO-CLAIMS fallback path, not the
runner's. A phantom CLAIMS row must reach the classifier and fail the way bash does.
(e) Resolution 12's "the bash gate-path copy dies at P3" means **the GATE CONSUMER stops spawning
`check-comments.sh`**. The file stays vendored: `core/comment-ratchet.sh:25` invokes it directly as the HOOK's
`SUBSTRATE_ENGINE=bash` rollback leg, which B1 requires to stay reachable. P5 deletes it with the rest of the engine.

**C10 — `SUBSTRATE_METRICS_OUT` lands in BASH FIRST, in W1.** The metrics JSONL is byte-frozen in the compat table but
is NOT witnessed against the runner: the aggregate `METRICS` file is a mktemp destroyed by the EXIT trap, and
`golden_replay_metrics` re-executes the checks itself, serially — so the vector tests the CHECKS, not the runner's
shard concatenation order. A Go runner appending shards on completion instead of in name order would pass today's
vectors. Add the sink mirroring `SUBSTRATE_CLAIMS_OUT`'s staged-mktemp-then-`mv -f`-with-umask-derived-chmod idiom
(`core/gate.sh:111-121`), published between `run_checks` and `ratchet`.
**[was wrong]** the first draft made the `cmp` "the FIRST action of W1" while landing the sink in W2 — the sink would
not exist. The sink is a W1 deliverable, and the `cmp` against today's `test/golden/metrics.jsonl` immediately
follows it. All three panel proposals ASSUMED the bytes match; that is unverified. If they differ, that is a
pre-existing defect the sink uncovered and W1 BLOCKS until it is explained — do not recapture and move on.

**C11 — reproduce the FIFO retirement window literally.** The comment at `core/gate.sh:157-158` is misleading:
`running` is SUBMITTED-MINUS-REPORTED, not a live-process count. It is incremented at submission and decremented only
inside the `if [ "$running" -ge "$max" ]` branch AFTER `report_check` returns, and `report_check` waits on ONE
specific pid — the oldest unreported. Job *k* is not submitted until job *k−max* has finished AND been reported:
head-of-line blocking, not a semaphore pool. A disabled name `continue`s BEFORE `running` is incremented, which is why
the position of `[!] <name>: disabled in substrate.json` moves with `SUBSTRATE_GATE_JOBS`. Do NOT build a worker pool
for the ~1.8× win — under A31 "more correct than bash is a FAILURE".

**Stdout alone cannot falsify this**: measured, each check's output is captured whole before printing and reporting is
strictly by ascending index, so a real pool and the FIFO window produce IDENTICAL stdout. W5 therefore ships
`test/gate-scheduler-test.sh` asserting the window through a SIDE CHANNEL (completion timestamps written by fixture
checks to a file the runner never reads): window liveness at jobs≥2, monotone stamps at jobs=1, and the
duplicate-metric-name last-writer rule.

**The unset default is the production path.** `core/gate.sh:165` is
`max=${SUBSTRATE_GATE_JOBS:-$(nproc 2>/dev/null || printf '4')}`, and every real invocation takes it. The engine
shells `nproc` with the same `4` fallback (bug-for-bug); `runtime.NumCPU()` would be a divergence. One oracle runs
both legs with the variable UNSET in the same process environment.

**C12 — the A/B oracle masks durations; it does not mask order.** **[was wrong]** the first draft's acceptance line
demanded byte-identical whole-gate stdout. Measured: two runs of the SAME leg differ in **16 of 24 lines** — every
`[ok] <check> (Nms)` and the trailer carry a wall clock. `test/gate-ab-test.sh` masks `(<duration>)` to a fixed token
and nothing else; line ORDER, line COUNT and every other byte stay under test. `format_duration`'s truncation
(`core/gate.sh:125-132`, measured 1099→`1.0s`, 1999→`1.9s`, 3661000→`3661.0s`, negatives falling to `%dms`) is pinned
separately by a table test under the A5 narrow waiver, since the mask hides it.

**C13 — the omp and bash repo-root probes.** `core/omp/substrate-quality/policy.ts:28` uses
`existsSync('.substrate/gate.sh')` as THE repo-root oracle for the enforcement layer, and `core/verify.sh:53` probes
the same path. P5's acceptance asserts that file is gone — at which point the extension silently deactivates with
nothing failing loudly. **[was wrong]** the first draft claimed only `policy.ts` was affected. Both change to
`.substrate/VERSION`, keeping the function name `findGateRoot`. The SAME commit runs `substrate bootstrap` and
restarts omp, because `core/verify.sh`'s 7-file aggregate sha256 covers `policy.ts` and `substrate verify` reds until
the runtime is re-observed. No automated CI oracle exists for consumer repos — it is a manual release-note step.
**Parent contradiction to resolve at P5, recorded here:** resolution 6 keeps "3-line exec shims for every path
external callers reference" while P5's acceptance asserts `! test -e .substrate/gate.sh`. If P5 ships a gate.sh shim,
C13 is hygiene; if not, it is required. Either way the probes move now.

## New amendments to the parent plan (binding)
- **A33 — P3's claim is ZERO edits to the BASH leg's EXISTING assertions, not zero test edits.** Mandatory:
  (1) `test/lib/golden-fixture.sh` `golden_run_gate` exports `SUBSTRATE_ENGINE="${GOLDEN_ENGINE:-bash}"` — today an
  ambient `substrate-engine` on PATH would silently capture or verify the frozen vectors on the GO leg;
  (2) the same function exports `SUBSTRATE_METRICS_OUT` and pins `SUBSTRATE_GATE_JOBS=4`;
  (3) `golden_write_manifest` records the engine identity; (4) `test/golden/manifest.json` recaptured for the new
  field only, vector BYTES proven unmoved; (5) `test/capture-golden-vectors.sh` follows (1)–(3);
  (6) NEW `test/gate-rollback-test.sh` — `test/engine-rollback-test.sh` iterates a hard-coded hook array and pipes a
  JSON payload to `bash .substrate/<script>`, a shape the gate cannot take, so the gate's rollback switch would
  otherwise ship UNPROVEN; (7) a dual-leg `gate-parity` CI job — **[was wrong]** the first draft justified this by
  claiming the gate job has no Go toolchain; verified false (`test/ci-toolchain.sh --active` installs it via the `go`
  profile). The true reason is that the gate job pins no engine binary and asserts no leg, so a PATH change could
  silently flip it; (8) `test/ab-hooks-test.sh` open-codes `go build` WITHOUT `-ldflags "-X main.version=…"`, so its
  engine reports `0.0.0-dev` and P2's B4 attestation is vacuous there — convert it to `engine_build`
  (`test/lib/engine-fixture.sh:27`), which every new P3 oracle must also use;
  (9) `test/claims-table-test.sh` gains an outer bash|go loop plus a `cmp -s` of the two tables — today it is
  single-leg and compares verdicts, not bytes, so the acceptance line it backs would be false;
  (10) `core/selftest.sh` gains a leg sweep; (11) `test/matrix.sh` and `test/hostile-home.sh` pin
  `SUBSTRATE_ENGINE=bash` so profile-matrix leg selection stops being ambient;
  (12) NEW suites: `test/gate-ab-test.sh`, `test/gate-env-probe-test.sh`, `test/gate-scheduler-test.sh`,
  `test/check-registry-test.sh`, `test/gate-inventory-guard-test.sh`, `test/claims-injectivity-test.sh`.
- **A34 — EIGHT A31 exceptions fire in P3**, by far the most attempted at once: C2 (accept-key grammar), C3b×2
  (baseline plain-path floor loss, direction loss), C4 (0x1F CLAIMS forgery), C5 (scoped-inventory fail-open), C8
  (empty checks.d), C9a (colon paths), C9c (locale-blind prose-block). **[was wrong]** the first draft counted four.
  Each lands as its OWN commit with its own A/B scenario, carries its measured evidence in the commit message, and
  must be independently revertible. If that count feels too large to land in one phase, split P3 — do not quietly
  drop exceptions.
- **A35 — the FIFO retirement window is frozen behaviour.** `running` is submitted-minus-reported; reporting is strict
  submission order; disabled names skip before increment; the unset `SUBSTRATE_GATE_JOBS` default shells `nproc` with
  a `4` fallback. Oracles pin the value (canonical 4). **[was wrong]** the first draft asserted "check discovery is
  byte-sorted"; `core/gate.sh:170` is a bash glob collated by `LC_COLLATE` (measured to reorder adversarial names
  between `C` and `en_US.UTF-8`). W2 pins `LC_ALL=C` on the discovery glob — legal, since gate.sh is not byte-frozen —
  making both legs deterministic.
- **A36 — the registry digest covers the VENDORED file**, so in the kit it depends on `checks.d/80-vendor-drift.sh`
  keeping `core/` ≡ `.substrate/`. P5 DELETES that check; its successor attestation check MUST inherit the obligation.
- **A37 — new P3 suites must isolate user state:** scratch `HOME` (prefer `engine_fixture_home`),
  `SUBSTRATE_NO_USER_HARNESS=1`, and `JJ_CONFIG` (jj resolves its user config via `XDG_CONFIG_HOME` BEFORE `HOME`).
  Exit 3 is reserved strictly for "prerequisite unfetchable" — `core/audit.sh` maps rc 3 to non-failing UNVERIFIABLE.
  The battery is authoritative only when run SERIALLY.
- **A38 — expected A32 structural-limit entries are named up front**, stderr is compared as its own stream, and each
  registry entry carries a reason string so the anti-rot assertion can fire: (i) jq's own parse diagnostics on a
  config that passes `jq -e .` but fails a later filter; (ii) the TAB-in-path `claims table build failed` path, which
  keeps jq's `Invalid literal at EOF` line the engine has no subprocess to emit; (iii) `nproc`-absent fallback noise.
- **A39 — validation is BUDGETED; the cost of proving a change must match the size of the change.** Measured on the
  primary workstation: `bash .substrate/gate.sh` **12 s**; one targeted suite **1–60 s**; the full serial battery of
  20 suites **877 s (~15 min)**; `bin/substrate audit` **1940 s (~32 min)** and rising with every acceptance line any
  plan adds. The rule:
  | change | proof |
  |---|---|
  | plan/docs text only | `bash .substrate/gate.sh` — nothing else |
  | one bash or Go file | the suites that cover it, named in the work item |
  | a work item lands | that item's merge gate ONLY |
  | the phase lands | full serial battery + `substrate verify`, ONCE |
  | `bin/substrate audit` | at phase landing, or when a plan's acceptance set changed — never as routine validation |
  A merge gate that names "the full battery" is a BUG in the plan unless the item genuinely changes global behaviour.
  Each P3 work item below names the smallest sufficient proof. Corollary for the A/B sweeps: the `{1,2,4,8}` job sweep
  runs on the scratch fixture (seconds), never on the kit repo (~150 s per invocation and vacuous there).

## Work items (ordered; the repo is green between every item)
- **W0 — plan only.** Land this file plus A33–A38 in `.pi/plans/go-rewrite.md`.
  *Merge gate:* `bash .substrate/gate.sh` green (12 s). **Nothing else** — this item changes only Markdown.
  For the record, measured after landing: `core/audit.sh` harvests every `- [ ] … :: …` line from any
  `draft|active|committed` plan, so this plan immediately contributes **8 pending + 6 passing** items and audit's
  runtime grows accordingly. **[was wrong]** the first draft's gate said "audit still exits 0 with 13 pending":
  the count is 8, and audit already exits **1** on this tree for two PRE-EXISTING regressions in
  `.pi/plans/completion.md` (`typescript constructs pack with oracle`, `svelte enforcing via svelte-check`) that have
  nothing to do with the Go migration. Fix or re-scope those separately; do not let P3 inherit the blame.
- **W1 — oracles and the metrics sink, bash-only.** Land `SUBSTRATE_METRICS_OUT` FIRST, then `cmp` its output against
  `test/golden/metrics.jsonl` (C10). Then the new suites of A33(12) plus the `test/baseline-test.sh` keyed-accept,
  tie-break, null-metric and route-(c) scenarios, the colon-bearing and adversarial-comment-text fixtures, and the
  non-ASCII prose fixture. Every new assertion except the metrics `cmp` must be RED for the right reason, and each
  must be proven red by deliberately reverting its future fix.
  *Merge gate:* the metrics `cmp` green or BLOCKING with an explanation; every other new assertion demonstrably red.
  Run only the new suites plus `bash .substrate/gate.sh` — no battery, no audit (A39).
- **W2 — the eight A31 bash fixes, ONE COMMIT EACH (A34), plus `LC_ALL=C` on the discovery glob and `RUN_DIR` in
  `cleanup()`.** **[was wrong]** the first draft said each commit "re-vendors `.substrate/` in the SAME commit";
  verified impossible — `core/checkpoint.sh` routes every path through `protect-paths.sh`, which hard-blocks
  `.substrate/*`. The real per-landing sequence is: edit `core/`, run
  `bin/substrate update --apply --force --checkpoint --message '<=50 chars>'` (the vendor transaction is the only
  authorised writer), then `substrate_checkpoint` the `core/` change. Each A31 fix is therefore a PAIR of commits,
  still independently revertible.
  *Merge gate:* per commit, only the suites that commit's fix touches (each A31 fix names them). ONCE at the end of
  W2, the full serial battery — not eight times (A39).
- **W3 — NUL-safe inventory listing on both backends, its own commit.** `git ls-files -z` and
  `jj file list -T 'path ++ "\0"'`, with `build_inventory` rewritten to `while IFS= read -r -d ''` fed by process
  substitution. **[was wrong]** the first draft's merge gate demanded identical inventories under both backends; `-z`
  fixes QUOTING, not ORDER, and the two orders are measurably different on this very repo (same 535-file set, `cmp`
  differs at line 194: git byte-sorts so `core/omp/substrate-quality.ts` precedes `core/omp/substrate-quality/`, jj
  groups the directory first). *Merge gate:* identical inventory SET under both backends.
  **Separate explicit ruling required before W3 lands:** either byte-sort the VCS inventory on both legs (a NEW
  A31-class divergence — it changes 05's finding order and 30's tie-break file in real repos) or freeze per-backend
  order and register it. Do not let the port decide this by accident.
- **W4 — registry artefacts, NO dispatch change.** `internal/gate/registry_gen.go`, its generator,
  `checks.d/82-check-registry.sh`, the doctor override warning. **[was wrong]** the first draft also moved
  `core/selftest.sh` to "the merged enumeration source" here; unbuildable — the registry lives only in Go, selftest is
  bash and is vendored to consumers that have no Go, and `--list-checks` does not land until W5. The selftest change
  moves to W5.
  *Merge gate:* mutating one byte of any `.substrate/checks.d/*.sh` without regenerating reds
  `82-check-registry.sh` while `80-vendor-drift.sh` stays green — proving the two checks are independent.
  **[was wrong]** the first draft's gate said "mutating `core/checks.d/*.sh`", which the digest definition makes
  impossible to detect.
- **W5 — Go runner skeleton + `--list-checks`, reachable only by direct `substrate-engine gate` through a thin
  harness exporting C1's five variables; every registry entry `Run == nil` so all checks still spawn as bash
  (row 5 of C8's table).** Preflight hand-off (sentinel 12), inventory, CLAIMS, spawn/scheduler/report. `core/selftest.sh`
  switches to `--list-checks` when a binary resolves and falls back to the glob otherwise. Deliverables:
  `test/gate-ab-test.sh`, `test/gate-env-probe-test.sh`, `test/gate-scheduler-test.sh`.
  **A/B fixture composition is specified here, not left to the porter:** one silent rc=1 check, one chatty rc=1 check,
  one `die_infra` rc=3 check, one stderr-only rc=0 check, one disabled check placed MID-sequence, two checks emitting
  the same metric name with inverted completion order, and one long check — otherwise five measured reporting
  asymmetries go untested.
  *Merge gate:* whole-gate A/B green with durations masked (C12) at the canonical `SUBSTRATE_GATE_JOBS=4` on the kit
  repo, and swept over {1,2,4,8} on the scratch fixture only — **[was wrong]** the first draft swept the kit repo,
  measured at ~76 s per leg per sweep (~150 s per invocation) and vacuous there because the kit's `checks.disabled` is
  empty, so the one job-count-sensitive observable never appears. Plus the env-probe (allowlist length 3,
  `_CLAIMS_STATE == table`) and the scheduler side-channel assertions.
- **W6 — Go ratchet and baseline writer** (parallel with W5/W7 only once `MetricRecord`, `Env` and the registry shape
  are pinned IN WRITING; all three touch `internal/gate` and `cmd/substrate-engine/main.go`).
  *Merge gate:* `test/baseline-test.sh` dual-leg with a cross-leg `cmp -s` of `substrate-baseline.json` after EVERY
  mutation; bug-pins green for `3.0`, `-0`, `1e100`, `1e-7`, `0.000001`, 21-digit, `1e400`→`1E+400`/`+Inf`, `nan`→
  `null`; a first-ever baseline is mode 0600 on both legs.
- **W7 — natives 05/15/30/40/10-comments** bound into the registry, plus C9c/C9d. Per-check bindings are written out
  before porting — **[was wrong]** the first draft ported five checks in one line. At minimum: 10-comments'
  `grep -F "$f:"` substring report filter (which measurably drags grandfathered findings from `xa.sh` into `a.sh`),
  the dropped last line, `jq -e` stream/truthy semantics as a decoder loop tracking the LAST value, 0x0A byte counting
  for 30-budgets, and 05's scope semantics.
  *Merge gate:* per-native A/B (bash check vs native) on the golden fixture BEFORE dispatch is wired;
  `test/check-registry-test.sh` proving a native runs with NO file present and an unknown discovered check still runs;
  `bash test/ab-hooks-test.sh` green under BOTH locales with the new fixtures.
- **W8 — the seam opens.** `capabilities` verb, `substrate_engine_supports`, gate.sh's delegation block with the
  foreground child and the 12→2 remap, the `gate-parity` CI job. Measure the probe's added exec cost and record it:
  `core/audit.sh` runs oracles concurrently each with a full repo copy, and `core/maintenance-transaction.sh:74-97`
  runs the gate TWICE per transaction.
  *Merge gate:* `test/gate-rollback-test.sh` green, then — as the phase's ONE integration run — the full serial
  battery on both forced legs (~30 min, budgeted once here; it doubles as the exit-criteria run, so do not repeat it
  in W9). W9 afterwards needs only `substrate verify`.
- **W9 — `policy.ts` + `core/verify.sh:53` probes (C13) + `substrate bootstrap` + omp restart, plus the docs pass.**
  `docs/contracts.md` omits `CLAIMS` from the check environment entirely, and `SUBSTRATE_FILE_LIST`,
  `SUBSTRATE_GATE_JOBS` and `SUBSTRATE_CLAIMS_OUT` appear nowhere in `docs/` despite being live inputs.
  *Merge gate:* `substrate verify` green after the restart; the aggregate hash intact.

## Open rulings required before implementation starts
1. **W3's inventory ORDER** — byte-sort both backends (new divergence, changes real findings) or freeze per-backend.
2. **`.checks.disabled` as a STRING** — `core/gate.sh:173` uses jq's `index`, which is SUBSTRING search for strings:
   measured, `.checks.disabled = "zz05-x.shzz"` disables `05-x.sh`. Reproduce bug-for-bug with a fixture, or fire a
   ninth A31 exception requiring an array.
3. **rc=70** — `core/gate.sh:140`'s `read … || { rc=70; ms=0; }` renders
   `[!] FAIL <name>: infrastructure failure (rc=70) — the gate cannot pass blind`. Name the Go condition that maps to
   it (recommended: `cmd.Wait()` returned a non-`*exec.ExitError`), keep the wording and `ms=0`, and add an A/B
   scenario that kills the job.
4. **Signal handling** — W2 adds `RUN_DIR` to bash's EXIT trap; state the Go obligation (remove temps, kill the check
   process group, re-raise so the process still dies BY the signal, preserving 130).
5. **Eight A31 exceptions in one phase** — confirm the appetite, or split P3 into P3a (bash remediation + oracles) and
   P3b (the Go port).

## Non-goals
- No transaction work (P4). No `.substrate/` deletion, no registration rewrite, no `check-comments.sh` deletion (P5).
- No worker-pool rewrite; no gate-lib.sh byte changes; no CLAIMS format change.
- No changed operator-visible failure paths except where an A31 exception explicitly says so.

## Acceptance
- [ ] the whole gate is byte-identical on both legs with durations masked :: bash test/gate-ab-test.sh
- [ ] the scheduler's retirement window and metric last-writer rule hold :: bash test/gate-scheduler-test.sh
- [ ] the gate's rollback switch is proven for the gate identity :: bash test/gate-rollback-test.sh
- [ ] the spawned-check environment is pass-through and complete :: bash test/gate-env-probe-test.sh
- [ ] the scoped-inventory guards fail closed and `--tighten` cannot erase a baseline :: bash test/gate-inventory-guard-test.sh
- [ ] a 0x1F path is rejected rather than forging a CLAIMS row :: bash test/claims-injectivity-test.sh
- [ ] the keyed accept-regression form works, ratchet and baseline agree, and floors survive :: bash test/baseline-test.sh
- [ ] metric literals, null, and jq's tie asymmetry survive a round trip :: bash -c 'go test ./internal/canonjson/... ./internal/gate/...'
- [ ] natives run with no file present and an unknown discovered check still runs :: bash test/check-registry-test.sh
- [ ] the frozen gate artefacts are unchanged, now including the metrics sink :: bash test/golden-vectors-test.sh
- [ ] the CLAIMS table is byte-identical across legs :: bash test/claims-table-test.sh
- [ ] selftest passes on both legs and enumerates through the registry :: bash core/selftest.sh
- [ ] every hook, the ledger and the receipts are untouched by P3 :: bash -c 'bash test/ab-hooks-test.sh && bash test/golden-ledger-test.sh && bash test/receipt-test.sh'
- [ ] harness parity and vendor integrity hold :: bash -c 'bash test/parity-test.sh && bash test/vendor-drift-test.sh'

## Exit criteria
Every oracle checked, the full battery green SERIALLY on both forced legs, `substrate verify` green after an omp
restart, the vendored mirror committed through its own maintenance transaction, then this plan flips to `committed`
and `.pi/plans/go-rewrite-p2.md` flips to `superseded` with a `superseded-by:` pointer (amendment A2).

## Operational notes (carried forward, all still true)
1. Vendored changes need two commits: `bin/substrate update --apply --force [--checkpoint --message '<=50 chars>']`
   first (its transaction is the authorised writer for `.substrate/**`), then `substrate_checkpoint` for kit source.
2. Never `export` into the persistent shell; use `env VAR=… cmd`.
3. Byte-comparing tests use only `test/.toolchain/bin/jq` (A4); ambient `jq` may be jaq.
4. Run the suite battery SERIALLY when the result matters (A37).
5. Files written exclusively by background subagents can be missing from the ownership ledger — write through
   blocking calls, or re-write the final bytes once through a direct tool call before checkpointing.
