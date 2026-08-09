# Plan: Go engine rewrite — P2 (receipts in-process + engine attestation)
state: superseded
superseded-by: .pi/plans/go-rewrite-p3.md
issue: https://github.com/mp-pinheiro/substrate/issues/12
parent: .pi/plans/go-rewrite.md

## Goal
Move exact-state gate-receipt authority into the Go engine behind the P1 seam, land fingerprint recipe v2 (versioned
per resolution 7, fixing the measured `%q`/locale/ordering hazards), route the gitleaks deep-scan cache key through the
engine byte-identically (amendment A28), and land `.substrate/engine.json` + doctor attestation (resolution 4, A10,
A14, A26).

Read first: `.pi/plans/go-rewrite.md` (12 binding resolutions, shared-artifact compat table, amendments A1–A32,
Decided section), then `.pi/plans/go-rewrite-p1.md` (what P1 landed and the operational notes it paid for). Both are
self-contained; no chat context is required.

## Method
Six parallel read-only contract extractions (recipe, consumers, gitleaks, enginepin, oracles, go-conventions —
151 contracts, 90 hazards, all with measured evidence), a 3-lens architecture panel (seam-safety / minimal-diff /
falsifiability) reconciled by 2 independent judges. The bindings below fold every accepted ruling. Where a work item
conflicts with a binding, the binding wins.

## Bindings (resolve the seven P2 forks; override any looser reading of the parent plan)

**B1 — Delegation seam, not a second implementation.** `core/receipt-lib.sh` keeps every public function name, argv and
return contract. Its current bodies are renamed `gate_receipt_matches_v1` / `write_gate_receipt_v1` and stay
BYTE-FROZEN — they are the `SUBSTRATE_ENGINE=bash` rollback leg and still compute recipe v1. The new public wrappers
resolve an engine binary and, under `auto`/`go`, CAPTURE (`$(...)`, never `exec`) `substrate-engine receipt matches` /
`substrate-engine receipt write …`. There is exactly ONE v2 implementation, in Go. Rationale: resolution 7 forbids
byte-chasing the recipe, so a bash v2 reimplementation would re-create the exact trap the resolution exists to forbid.

**B2 — Verb surface and version-skew safety.** `cmd/substrate-engine/main.go`'s top-level switch gains three sibling
cases beside `version` and `hook`: `receipt`, `gitleaks-deep-key`, `pin`. Argv grammar:
- `receipt fingerprint` — 64-hex + LF on stdout, rc 0; rc 1 on refusal (no stdout).
- `receipt matches` — rc 0 match, rc 1 no-match-or-refusal, no stdout.
- `receipt write <source> <commit> <vcs> [session]` — positional, mirroring `write_gate_receipt`; receipt JSON + LF on
  stdout, rc 0; rc 1 on failure.
- `gitleaks-deep-key` — 64-hex + LF on stdout, rc 0; rc 1 on failure.
- `pin emit` — `{"version":…,"binary_sha256":…}` + LF for the engine's OWN executable, rc 0; rc 1 on failure.

**Exit code 2 is reserved EXCLUSIVELY for `main.go`'s unknown-verb `default:`.** No handler may return 2 for its own
errors. Bash wrappers treat rc 2 as "this binary predates the verb" and fall back to the `_v1` body; every other rc is
authoritative. This convention is standing and binds every future non-hook verb (P3/P4/P5).

**B3 — Receipt schema and invalidate-once.** The receipt gains ONE key, `recipeVersion` (number), inserted directly
after `engineVersion` in the `jq -cn` insertion order:
`{commit,vcs,source,session,fingerprint,reusable,engineVersion,recipeVersion,state,at,status}`.
Only the Go writer emits it, always `2`. The `_v1` bash body is not touched — a v1 receipt simply lacks the key.
The Go reader's precondition is `.status=="passed" and .reusable==true and (.fingerprint|type=="string") and
.recipeVersion==2`; a v1 receipt is therefore refused exactly once and regenerated. The `_v1` reader needs no change:
it recomputes a v1 fingerprint, which never equals a v2 one.
Named `recipeVersion`, not `schemaVersion`, because resolution 7 versions the FINGERPRINT RECIPE, not the document
shape; `core/maintenance-receipt.sh:41-43`'s `schemaVersion` keeps its own distinct meaning.
**Consequence to state loudly:** bash-forced and engine-delegated receipts are two permanently disjoint generations.
Flipping `SUBSTRATE_ENGINE` always costs exactly one gate run. That is the designed behaviour, not a bug.

**B4 — engine.json is kit-authored, tracked, and host-deterministic.** Schema is flat, exactly two keys:
`{"version":"<kit VERSION>","binary_sha256":"<64 lowercase hex>"}`. The optional `path` of A10 is NOT written at P2 and
no store dir is introduced — the pinned installer that would populate one is explicitly P5 scope
(`.pi/plans/go-rewrite.md:98`), and a redirect nothing populates is dead code.

The pin is authored in the KIT at `<KIT_ROOT>/engine.json` and copied verbatim by `vendor_core` (`bin/substrate:95`
copies `VERSION` the same way) into `.substrate/engine.json`. It is written by `bin/substrate engine pin [--bin PATH]`,
which shells `"$bin" pin emit`. **`engine pin` is a deliberate release action, never a per-rebuild one** — the pin
moves when an engine version is cut, so a tracked file stays host-stable and never churns maintenance. Dev rebuilds
never re-pin; they set `SUBSTRATE_ENGINE_BIN`, which is precisely A14's warning downgrade.

**It must be tracked, and therefore host-independent, for two independently fatal reasons.** (i) Nothing in the
installer manages `.gitignore` (verified — `core/install-assets.sh:71` only lists it inside the `unscanned` ledger), so
an untracked `.substrate/engine.json` leaves every consumer's working copy permanently dirty, `working_copy_clean`
fails (`core/receipt-lib.sh:37-45`), and receipts are never reusable again. (ii) `core/ci/github-gate.yml` is a bare
checkout → `.substrate/gate.sh` → `.substrate/audit.sh` with no render step, so `vendor_core` never runs in CI; a
gitignored pin would not exist there and every acceptance oracle naming it would be red forever (A2 re-executes
committed plans). Deriving the sha from whatever binary sits on the renderer's PATH would reintroduce host variance
into a tracked file. Never create `core/engine.json` and never add `engine.json` to
`checks.d/80-vendor-drift.sh`'s `CORE_SCRIPTS` (`:24-30`); the check then needs zero edits and doctor owns the file,
per `.pi/plans/go-rewrite.md:72`.

`-ldflags "-X main.version=$(cat VERSION)"` MUST land in the same commit, in EVERY path that builds
`./cmd/substrate-engine` — `justfile`'s `engine` and `test-engine` recipes and every CI step — or A14's dev-build
downgrade fires universally and the attestation is permanently vacuous (`cmd/substrate-engine/main.go:11` is
`0.0.0-dev` today).

Doctor link (inserted after `core/doctor.sh:144`, reusing the `$engine_bin`/`$engine_version` already resolved at
`:118-124`), exact strings:
- pin present + resolved binary whose sha matches → `[ok] engine pin: <version> attested (sha256 <first12>)`
- pin present + no binary resolved → `[ok] engine pin: <version> pinned (sha256 <first12>) — no local engine to attest`
- A14 downgrade (`$engine_version` matches `0.0.0-*` OR `SUBSTRATE_ENGINE_BIN` is set) → `[!] engine pin: <reason>`
- pin missing → `[!] engine pin: .substrate/engine.json missing — run: substrate update --apply`
- pin malformed → `[!] engine pin: .substrate/engine.json is malformed — run: substrate engine pin`
- mismatch on a stamped build with no override → `die "engine pin: <bin> sha256 <first12> does not match .substrate/engine.json (<pinned first12>)"` (exit 2)

The pin link is reported UNCONDITIONALLY, not only when a binary resolves. An earlier draft made it conditional; that
made acceptance oracle 6 unsatisfiable in CI, where `core/ci/github-gate.yml` is a bare checkout → gate → audit with
no Go toolchain and no engine binary. Engine ABSENCE stays fail-open per resolution 3 — the existing
`[+] engine: auto falls back to bash` line still carries that fact.

**B5 — recipe v2 normalisations.** Adopted unanimously by the panel; each is inside resolution 7's mandate, not an A31
violation, because v2 is a NEW versioned recipe rather than a port of v1.
| Hazard | Verdict | v2 behaviour |
|---|---|---|
| H1 `printf %q` is LC_CTYPE-dependent (measured: `café` → `$'caf\303\251'` under C, raw under UTF-8) | NORMALISE | raw path bytes with NETSTRING length-prefixed fields and records (`<decimal-length>':'<bytes>`); no escaping, no locale, no reserved byte |
| H2 env record captures LANG/LC_ALL but not LC_CTYPE | DROP | remove LANG, LC_ALL and the provably-always-empty SUBSTRATE_FILE_LIST from the record |
| H3 `git ls-files` and `jj file list` return different orders, no sort applied (measured: two digests) | NORMALISE | explicit `bytes.Compare` sort after listing, both backends |
| H4 `./x` and `x` both survive dedup (measured: 3 files hashed twice) | NORMALISE | one canonical repo-relative spelling, no `./`, before dedup |
| H6 missing `.substrate` yields the empty-input digest and returns 0 | NORMALISE, **A31 exception** | fail closed on BOTH legs when the root is missing, is not a directory, OR yields an EMPTY record set |
| H8/H9 refs hash eats jj's human renderer incl. commit subjects and `(behind by N commits)` | NORMALISE | `jj bookmark list -T` machine template; one merged, byte-sorted record set with `git-ref`/`jj-bookmark`/`head` type tags; detached HEAD is an explicit record |
| H12 package.json walk escapes into `$HOME` | NORMALISE | bounded to the binary's own install root |
| H14 TAB/LF field injection in `%s` records | NORMALISE | subsumed by H1's length-prefixed framing, which is injective — a separator-only scheme is NOT (0x1F and 0x1E are legal path bytes; a reviewer forged a fingerprint collision against the first draft) |
| H20 silent jj→git backend flip changes four inputs at once | NORMALISE | `vcs` recorded in the state document; jj metadata present but jj unavailable is a refusal, not a downgrade |
| H10 GNU `stat -c %a` / `readlink -f` | KEEP semantics | `os.Lstat` + the FULL mode including setuid/setgid/sticky (`Mode().Perm()` alone silently drops them and was measured to miss `chmod 4755`), `os.Readlink`, `filepath.EvalSymlinks` |
| H11 `command -v` PATH dependence | KEEP | PATH sensitivity is the point; only shell-function resolution is excluded |
| H18 HOME/BUN_INSTALL/CI + SDK hash | KEEP | this is the intended environment attestation; `test/receipt-test.sh:7-11` depends on it |
| H24 `at` timestamp outside the fingerprint | KEEP | unchanged format, still excluded from the digest |
The state document keeps its seven hash fields and gains `recipeVersion` and `vcs`, serialised sorted-key via
`internal/canonjson` — no external JSON tool participates in the digest. The receipt embeds those SAME sorted bytes,
preserving bash's measured contract C18: `sha256(compact .state + LF) == .fingerprint`, so a receipt stays auditable
from its own contents.

**B6 — Oracles.** `test/receipt-test.sh` becomes dual-leg and self-building (A1/A25); `test/receipt-cross-engine-test.sh`
pins the disjoint-generation contract; `test/gitleaks-deep-test.sh` gains a byte-identity assertion between the Go verb
and bash `gitleaks_deep_key`; `test/doctor-attestation-test.sh` proves all four doctor branches. Golden vectors freeze
the v2 per-hasher RECORD ENCODINGS (not the final fingerprint, which is machine-bound) under `test/golden/receipt/`,
byte-tested from Go under the A5 narrow waiver. Receipt scenarios do NOT join `test/ab-hooks-test.sh`'s 90-row matrix:
its fixture declares non-empty `contracts`, which makes `gate_state_json` refuse unconditionally
(`core/receipt-lib.sh:224-225`) — folding them in would be vacuous. One scenario is added there, `gbp-receipt-hit`,
because push-gate stays bash and the existing stub interception still works.

**B7 — gitleaks-deep is key-only.** The Go verb replaces the BODY of `gitleaks_deep_key()` and nothing else. The argv
`case` (`core/gitleaks-deep.sh:18-23`), the usage line, the cache read/write and every message stay in bash, so `$0`
never has to be forged. The Go implementation shells out for subprocess truth (`git for-each-ref`, `git rev-parse HEAD`
with bash's `|| true` swallow, `gitleaks version`) and does sort/dedupe/hash natively; `tr -d '\r\n'` is a byte DELETE
filter, never `TrimSpace`. The deep-scan receipt bytes are unchanged — it is a cache artifact, and A28 freezes it.

## Files in scope
- New: `internal/receipt/` (state document, v2 hashers, fingerprint, receipt IO, `gitleaks.go`, `dispatch.go`),
  `internal/enginepin/`, `engine.json` (kit root), `test/receipt-cross-engine-test.sh`,
  `test/doctor-attestation-test.sh`, `test/golden/receipt/**`.
- Changed: `cmd/substrate-engine/main.go`, `core/engine-shim.sh` (+ non-exec `substrate_engine_bin` resolver),
  `core/receipt-lib.sh`, `core/gitleaks-lib.sh`, `core/doctor.sh`, `bin/substrate` (`vendor_core` copy + `engine pin`
  verb), `justfile`, `.github/workflows/*`, `test/receipt-test.sh`, `test/gitleaks-deep-test.sh`,
  `test/ab-hooks-test.sh`, `.substrate/**` (re-vendored).
- Explicitly NOT changed: `core/push-gate.sh`, `core/gated-push.sh`, `core/hooks/gate-before-push.sh`,
  `core/checkpoint.sh` call sites, `checks.d/80-vendor-drift.sh`, the deep-scan receipt bytes.

## Non-goals
- No gate-runner or transaction work (P3, P4). No `.substrate/` deletion, no registration rewrite (P5).
- No binary store, no installer, no `path` redirect (P5).
- No change to the push/checkpoint orchestration or to any operator-visible message string.

## Acceptance
- [x] the engine answers the P2 verbs and reserves rc 2 for unknown verbs only :: bash -c 'd=$(mktemp -d); go build -trimpath -buildvcs=false -ldflags "-X main.version=$(cat VERSION)" -o "$d/substrate-engine" ./cmd/substrate-engine || exit 1; "$d/substrate-engine" receipt fingerprint >/dev/null 2>&1; [ $? -ne 2 ] || exit 1; "$d/substrate-engine" gitleaks-deep-key >/dev/null 2>&1; [ $? -ne 2 ] || exit 1; "$d/substrate-engine" pin emit >/dev/null || exit 1; "$d/substrate-engine" nope >/dev/null 2>&1; [ $? -eq 2 ]'
- [x] the gate receipt round-trips on both legs with the same call sites :: bash test/receipt-test.sh
- [x] bash-written and engine-written receipts are disjoint generations that each self-heal in one run :: bash test/receipt-cross-engine-test.sh
- [x] the deep-scan cache key is byte-identical on both legs and the argv grammar is frozen :: bash test/gitleaks-deep-test.sh
- [x] doctor attests the pinned engine, downgrades dev builds, and dies on a real mismatch :: bash test/doctor-attestation-test.sh
- [x] the engine pin is present, well-formed, and doctor asserts it :: bash -c 'jq -e "(.version|type==\"string\") and (.binary_sha256|test(\"^[0-9a-f]{64}$\"))" .substrate/engine.json >/dev/null && esc=$(printf "\033") && out=$(bin/substrate doctor 2>&1) && clean=${out//${esc}\[0;34m/} && clean=${clean//${esc}\[0;32m/} && clean=${clean//${esc}\[0;33m/} && clean=${clean//${esc}\[0m/} && printf "%s\n" "$clean" | grep -qE "^\[(ok|!)\] engine pin: "'
- [x] the v2 record encodings match their frozen vectors :: bash -c 'go test ./internal/receipt/...'
- [x] every hook still answers identically on both legs in both locales :: bash test/ab-hooks-test.sh
- [x] the ledger, stop branch and frozen gate artifacts are untouched by P2 :: bash -c 'bash test/golden-ledger-test.sh && bash test/ab-stop-test.sh && bash test/golden-vectors-test.sh'
- [x] SUBSTRATE_ENGINE=bash still restores the bash leg everywhere :: bash test/engine-rollback-test.sh
- [x] the receipt-adjacent suites pass unmodified :: bash -c 'bash test/checkpoint-test.sh && bash test/restructure-test.sh && bash test/maintenance-test.sh && bash test/vcs-hooks-test.sh'
- [x] harness parity and vendor integrity hold :: bash -c 'bash test/parity-test.sh && bash test/vendor-drift-test.sh'

## Exit criteria
Every oracle above checked, `substrate verify` green after an omp restart, the vendored mirror committed through its
own maintenance transaction, then this plan flips to `committed` and `.pi/plans/go-rewrite-p1.md` flips to
`superseded` with a `superseded-by:` pointer (amendment A2).

## Operational notes carried forward from P1 (still true)
1. Vendored changes need two commits: `bin/substrate update --apply --force` first (its transaction is the authorised
   writer for `.substrate/**`), then `substrate_checkpoint` for the kit source.
2. Never `export` into the persistent shell; use `env VAR=… cmd`.
3. Byte-comparing tests use only `test/.toolchain/bin/jq` (A4); ambient `jq` may be jaq.
4. Files written exclusively by background subagents can be missing from the ownership ledger — write through blocking
   calls, or re-write the final bytes once through a direct tool call before checkpointing.

## Landed 2026-08-07 — decisions and corrections made during implementation
- **The recipe-v2 framing was WRONG in the first draft and an adversarial pass caught it.** B5's original H1/H14 row
  specified raw bytes with `0x1F` field / `0x1E` record separators. Both bytes are legal in POSIX paths, so the framing
  was not injective: a reviewer built two materially different configuration states with one fingerprint
  (`30404475492df454…`) using a crafted directory name. v1's `printf %q` did NOT have that hole, so the first draft
  shipped a REGRESSION while claiming to close the hazard. The framing is now netstring length-prefixed
  (`<decimal-length>':'<bytes>`), which is injective by construction. Lesson for P3/P4: a reserved-byte delimiter over
  arbitrary path bytes is never safe — length-prefix or escape.
- **The engine pin had no fixed point until `-trimpath -buildvcs=false` landed.** Go's default `-buildvcs=auto` stamps
  `vcs.revision`/`vcs.modified` into the binary and, without `-trimpath`, the absolute build path is embedded (71
  occurrences measured). The first pin was therefore cut from a dirty tree at one absolute path and was unreachable by
  anyone, including its author, the moment the change was committed. Every build path in the repo now carries both
  flags; two builds from different absolute paths were verified byte-identical before re-pinning.
- **Acceptance oracle 6 was unsatisfiable as first written.** `bin/substrate`'s `success`/`warn` colour output
  unconditionally, so `grep -qE '^\[(ok|!)\]'` can never match — the line starts with an ESC byte. The oracle now
  strips ANSI first. Any future oracle that greps doctor output must do the same.
- **The doctor pin link is unconditional, deviating from the first draft of B4.** Gating it on "a binary resolved"
  made the oracle red in CI, which has no Go toolchain and no engine binary. A sixth branch — pin present, nothing to
  attest — reports the pin without claiming attestation.
- **`substrate_engine_bin` fails closed on forced `go`, like `substrate_engine_exec` always did.** The first draft
  collapsed the resolver's rc 2 into rc 1, so `SUBSTRATE_ENGINE=go` with no usable binary silently answered from the
  frozen bash leg and wrote a v1 receipt with rc 0 — which would have made every future forced-go A/B oracle vacuous.
  The two rc 2s are now distinct by construction: resolver-rc2 (forced go, no binary) is a hard failure read before any
  binary runs; binary-rc2 (unknown verb / version skew) is the fallback trigger read after.
- **B5's H6 A31 exception was half-applied and is now whole.** The Go leg refused a missing `.substrate`; the frozen
  bash `_v1` leg still returned the empty-input digest with rc 0. A31 requires both legs in the same batch. Both now
  fail closed on missing, non-directory, AND empty engine trees — the empty case was silent on both legs.
- **Contract C18 is preserved deliberately.** The receipt embeds the same sorted bytes the fingerprint hashes, so
  `sha256(compact .state + LF) == .fingerprint` still holds and a receipt remains auditable from its own contents.
- **The duplication ratchet blocked the landing and was paid down, not waived.** Four near-identical
  enumerate → record → digest hashers were factored behind one `hashItems` driver, and the two engine-delegation bash
  wrappers behind one `_substrate_engine_delegate`. `dup_pct` finished BELOW its pre-P2 baseline.
- **`test/restructure-test.sh` is flaky under parallel execution** ("squash result lost one.sh"), passing reliably in
  isolation. The suites contend on user-level state; run the battery serially when a result matters.
- **Verified self-sufficiency:** `core/receipt-lib.sh` and `core/gitleaks-lib.sh` still degrade cleanly to their `_v1`
  bodies when `engine-shim.sh` is absent entirely, so a partially-vendored consumer mirror falls back rather than
  failing with `command not found`.
