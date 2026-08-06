# Plan: baseline orphan semantics — prune by direction, never silently
state: committed
issue: https://github.com/mp-pinheiro/substrate/issues/12

## Goal
Decide and implement what `--tighten` does with a baseline key the current run did not emit. The runner garbage-collected such keys silently on every checkpoint; `test/baseline-test.sh` asserted the opposite (retain everything). One of the three — runner, test, or contract — had to move. This plan records which, and why.

## Files in scope
- `core/gate.sh` (`write_baseline`) — direction-aware orphan handling plus a prune report.
- `docs/contracts.md:76,86` — the SSOT text for the ratchet and the baseline.
- `test/baseline-test.sh` — corrected assertions; the probe check gained `metric_hi` support and the higher-is-better path gained its first coverage.

## Research: how comparable tools treat a stale baseline entry
| Tool | Stale entry | Pruning requires | Reported as |
|---|---|---|---|
| PHPStan | retained, hard error (`reportUnmatchedIgnoredErrors: true` default) | explicit `--generate-baseline` | error |
| Psalm | retained, hard error | explicit `--update-baseline` | error |
| ESLint >= 9.24 | retained, exit 2 (`--pass-on-unpruned-suppressions` opts out) | explicit `--prune-suppressions` | error |
| mypy-baseline | retained, hard error (`--allow-unsynced` opts out) | explicit `sync` | error |
| Android lint | retained, non-failing finding (`BASELINE_FIXED`) | explicit `--remove-fixed` / `--update-baseline` | info |
| Betterer | auto-pruned locally, error in `ci` mode | — | error in CI |

Not one tool prunes silently. Android lint states the reason a substrate reader should recognise: a baseline entry that no longer matches means "the problem has either been fixed, or perhaps the issue type has been disabled". mypy-baseline states the other half: keeping the file synced is what lets reviewers see what a change actually resolved.

Sources: https://phpstan.org/user-guide/baseline, https://phpstan.org/user-guide/ignoring-errors#reporting-unused-ignores, https://eslint.org/docs/latest/use/command-line-interface#--prune-suppressions, https://github.com/orsinium-labs/mypy-baseline, https://android.googlesource.com/platform/tools/base/+/refs/heads/mirror-goog-studio-main/lint/libs/lint-api/src/main/java/com/android/tools/lint/client/api/LintBaseline.kt

## Decision
Neither the old runner nor the old test. Both were wrong in different directions, and the deciding evidence is substrate's own design rule 2 — "block-and-report; never silently mutate" — read against the measured behaviour of each metric direction.

- **Lower-is-better orphan: prune.** An absent `lo` key already means zero tolerance (`ratchet` reads `$b[.key] // 0`), so pruning tightens to the strictest possible value. Verified: baseline `{}` plus emitted `dup_pct: 1.5` is reported worse. Retaining the old ceiling instead — which the test demanded — would let resolved debt return silently up to that ceiling. The test was asking for the looser behaviour.
- **Higher-is-better orphan: retain ceiling and direction.** For `hi` the same absence means *no floor at all*, the weakest possible state, and dropping the direction re-reads the metric as lower-is-better. Verified: with direction lost, `coverage: 3` is reported "worse than baseline 0" — fail-closed but for an incoherent reason; with ceiling and direction retained, it is correctly reported against 90.
- **Every prune is reported.** This is the part no prior-art tool omits and the part the runner was missing. A prune is either good news (debt fixed) or the only evidence that a check stopped running; on the checkpoint path it happened silently on every commit.
- **The contract moved too.** `docs/contracts.md` said "garbage-collects orphaned keys" and "an absent metric key means zero tolerance" without qualification. Both now state the direction-aware rule, so the SSOT describes the runner.

Rejected: per-metric provenance in the baseline (retain only keys whose owning check did not run). It is the textbook answer, but it needs a baseline schema change that would touch the frozen golden vector and every consumer, and direction — data the baseline already carries — separates the safe case from the unsafe one without it.

## Non-goals
- No change to regression detection, `--accept-regression`, initial-debt adoption, or the atomic write protocol.
- No baseline schema change; `{metrics, direction}` is untouched.
- Per-file metrics (`comments:<path>`) keep prune-on-absence, which is correct for them: `10-comments.sh` defaults a missing ceiling to zero, so a returning comment is caught.

## Acceptance
- [x] a lower-is-better orphan is pruned and reported while a higher-is-better orphan keeps its floor and direction :: bash test/baseline-test.sh
- [x] the negative-test battery still holds, including corrupt-baseline hard-exit :: bash .substrate/selftest.sh
- [x] frozen gate artifacts are unchanged by the new merge :: bash test/golden-vectors-test.sh
- [x] checkpoint and maintenance tightening still pass :: bash -c 'bash test/checkpoint-test.sh && bash test/maintenance-test.sh'
- [x] gate green :: bin/substrate gate
