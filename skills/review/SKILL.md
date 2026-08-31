---
name: review
description: Deterministic-first review of the current change — run the repo's checks, read the diff, report findings grounded only in that output and the diff.
allowed-tools: Bash(jj:*), Bash(git:*), Bash(just:*), Read, Grep, Glob
---

Review the working change with tool output as the ground truth. Opinions must cite a line; style commentary the checks did not flag is out of scope.

# Steps

1. Run the deterministic layer and capture its full output: `substrate gate` (or `.substrate/gate.sh`) when `.substrate/VERSION` exists, otherwise the repo's own check entry point (justfile target, package script, Makefile target). If the repo has neither, say so and review from the diff alone.
2. Get the change: `jj diff` (if `@` is empty, `jj diff -r @-`); in git-only repos, `git diff HEAD`.
3. Review ONLY what changed, in this order:
   - Correctness: logic, edge cases, failure modes in the changed lines.
   - Contract adherence: check contract, profile claims, and boundaries in `docs/contracts.md`; gate-lib helpers usage in checks.
   - Regressions: does the diff weaken a check, loosen a ratchet or baseline, widen the unscanned ledger, or bypass a hook? In a governed repo, if the diff shows an `accepted` entry in substrate-baseline.json, read the recorded reason and judge whether it is justified.
   - Plan drift: if `.pi/plans/` has an active plan, do checked acceptance claims still hold? (In a governed repo, `substrate audit` executes them.)
4. Report:
   - Deterministic verdict (pass/fail + failing checks verbatim, or `none` when the repo has no check entry point).
   - Findings as `file:line — problem — why it matters`, most severe first.
   - Verdict: `ship` or `fix first:` followed by the ordered fix list.

# Rules

- No edits in this session; review only.
- Never restate the diff or narrate what the code does — findings only.
- A claim without a `file:line` citation does not go in the report.
