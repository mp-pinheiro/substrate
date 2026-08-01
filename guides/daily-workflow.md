# Daily Workflow

The loop for any change, human- or agent-driven:

```
scope → edit → substrate gate → commit → push
```

## 1. Scope (optional but pays off for non-trivial tasks)

Use the `context-pack` skill to produce a brief in `.pi/plans/<slug>.md`: goal, exact files, contracts that apply, one exemplar file to imitate, non-goals, acceptance. Then implement in a **fresh session** against that pack. Rationale: agents miss context they didn't load; the pack makes the right files impossible to miss.

Acceptance items use the tracked, executable form (enforced by `15-tracking.sh`, executed by `substrate audit`):

```
- [ ] claim in plain words :: verify-command-that-exits-0
```

Both skills (`context-pack`, `review`) are installed into `.claude/skills/` by `substrate init` when absent.

## 2. Edit — and what the hooks will do

Write-time hooks run on every Write/Edit in both harnesses (Claude Code hooks + omp extension). You will see blocks like:

```
blocked: substrate-baseline.json changes only via .substrate/gate.sh --update-baseline
blocked: .substrate/ is vendored — change the kit and run substrate update --apply
blocked: <file> is a symlink to <target> — edit the target explicitly if that is intended
```

These are not suggestions — the write was rejected. If a block is wrong, the thing to change is `.substrate/hooks/protect-paths.sh` at its source (`core/hooks/` in the kit) and its omp mirror, not the workflow around it.

After a successful write, the comment ratchet checks the touched file:

```
src/foo.sh:12: narration: # now we check the thing
comment ratchet: src/foo.sh has 1 finding(s), grandfathered allowance is 0.
```

Fix by deleting the comment or encoding the fact in names/structure. For the rare keeper, append `gate:allow-comment` to the line — hatch semantics in [`docs/contracts.md`](../docs/contracts.md).

## 3. Gate

```sh
substrate gate        # or: .substrate/gate.sh, or: just gate
```

Red output names the file, the line, and the fix — see [working-with-the-gate.md](working-with-the-gate.md) for the failure-to-action map.

## 4. Commit

One logical change per commit; short subject, no body. Keep the plan artifact honest: check acceptance boxes only when their `:: verify` command is green — `substrate audit` re-executes every checked claim and fails on regression.

## 5. Push

With `push_gate: true` in `substrate.json`, the push hook runs the gate first. A blocked push prints the full gate report plus:

```
push blocked: fix the failing gate checks first
```

## 6. Review (when it matters)

The `review` skill runs the gate, reads the diff, and reports findings only with `file:line` citations — tool-grounded, not vibes. Use it before pushing anything you wouldn't want to debug later.

## Daily maintenance report

GitHub refreshes the open `substrate-report` issue every day at 06:00 UTC. Run the same report locally whenever you want a current view:

```sh
substrate report
```

The report is advisory. It separates duplicate-code candidates, possible dead code, and baseline limits, and it never fails the gate.
