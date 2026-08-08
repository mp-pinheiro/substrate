# Daily Workflow

The loop for any change, human- or agent-driven:

```
scope → edit → direct verification → checkpoint → explicit push
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

## 3. Verify and checkpoint

Run the changed behavior directly. OMP then calls its `substrate_checkpoint` tool; Claude's lifecycle supplies the equivalent session-bound command. The transaction commits only agent-owned paths: it runs the gate, lowers improved baseline ceilings atomically, commits locally with jj/Git, and records a receipt. When unowned pending work exists it gates the exact commit tree in an isolated candidate, leaves the unowned paths in place, and surfaces them; a checkpoint that ends clean reruns the gate in place and records a reusable exact-state receipt. At session stop, green owned work is checkpointed automatically. It never pushes.

For a human-driven change:

```sh
substrate checkpoint --message 'fix(scope): concise subject' --path path/to/file
```

Initial baseline creation and regression acceptance remain explicit:

```sh
substrate baseline
substrate baseline --accept-regression=max_file_lines --reason "file count grew with new profiles; splitting them into N files adds more overhead than the line count"
```

Each acceptance requires a written reason that is committed to `substrate-baseline.json` and reviewed in the diff. Failing to provide one produces a usage error.

## 4. Push

Push remains a user decision. `jj push` and Git's pre-push hook accept the checkpoint receipt only while the revision, working tree, refs, configuration, vendored checks, and toolchain still match exactly; otherwise they rerun the gate. There is no configuration opt-out. Because jj exposes no native push hook, an unsupervised low-level `jj git push` is outside the installed alias; OMP and Claude intercept the same command when an agent issues it.

```
push blocked: fix the failing gate checks first
```

## 5. Review (when it matters)

The `review` skill runs the gate, reads the diff, and reports findings only with `file:line` citations — tool-grounded, not vibes. Use it before pushing anything you wouldn't want to debug later.

## Repository maintenance

Kit synchronization uses a separate transaction from an agent checkpoint:

```sh
substrate bootstrap --checkpoint
substrate update --apply --checkpoint
```

Substrate renders and gates a scratch candidate before replacing managed paths. The checkpoint commit contains only those paths; unrelated dirty work remains in place. A run without `--checkpoint` can preserve or merge dirty repo-owned scaffold inputs, but leaves them uncommitted. Checkpoint mode refuses those inputs. Other dirty managed overlap or concurrent changes stop the command. If apply, commit, repository runtime wiring, or user-harness synchronization is interrupted, rerun the same command. The repository receipt identifies the unfinished phase. Neither command pushes.

Use `--accept-baseline` only for the first baseline, `--repo-only` to skip user-harness synchronization, and `--json` when another tool will consume the receipt.

## Daily maintenance report

OMP and Claude refresh ignored local `substrate-report.md` state at session start when it is due. GitHub refreshes the durable open `substrate-report` issue every day at 06:00 UTC. Render the current report without writing local state with:

```sh
substrate report
```

The report is advisory. It separates duplicate-code candidates, possible dead code, baseline limits, and raised ceilings, and its age or generation never changes the gate verdict.
