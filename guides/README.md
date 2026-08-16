# Substrate Guides

How to work in a repo where quality enforcement is deterministic. The premise: instructions in prompts decay, so every rule that matters lives in a tool that rejects violations — at write time, commit time, or merge time.

These guides are task-oriented: they show you what to do and what failures look like. The rules themselves (check contract, profile schema, ratchet semantics, escape hatches) live in **one** place — [`docs/contracts.md`](../docs/contracts.md) — and are linked, never restated, so they cannot drift.

## The mental model

```
you / the agent writes
        │
        ▼
L1  write-time hooks        ms feedback: protected paths, symlinks, comment ratchet
        │
        ▼
L2  direct verification + checkpoint
        │                 gate, tighten, exact local commit
        ▼
L3  push guard + CI gate   stale or red state blocks publication
        │
        ▼
L4  review + human merge   tool-grounded review; you own what lands
```

A mutating agent task is done when direct verification has passed and `substrate checkpoint` has recorded a green exact-state receipt. Push remains a separate user action. Green is trustworthy: every detector fails the gate loudly when its own tooling breaks (`cannot pass blind`), so a passing run means everything actually ran.

## Where everything lives

| Path | Role |
| --- | --- |
| `substrate.json` | repo config: active profiles, unscanned ledger, budgets, disabled checks |
| `substrate-baseline.json` | grandfathered debt snapshot and accepted-regression records; only the gate runner may write it |
| `.substrate/` | vendored bash (remaining linter-wrapper checks, hook shims, langmap); the gate engine itself is the separately-installed `substrate-engine` Go binary. `substrate bootstrap --checkpoint` synchronizes the vendored copy with the kit |
| `.substrate/checks.d/` | active checks: core 05–59, profile 60–79, repo-local 80–99 |
| `.claude/{agents,skills}/`, `.omp/{agents,skills}/` | working agents and skills; unmarked same-name assets are repo-owned, while a `.substrate-managed.json` marker grants full kit ownership and stale marked assets are removed |
| `profiles/<name>/` | kit profiles: `profile.json` (claims, checks, fixtures), `checks.d/`, `templates/` |
| `substrate-profiles/<name>/` | repo-local profiles, same schema |
| `checks.d/` (repo root) | repo-local checks, vendored in at 80–99 |
| `.pi/plans/*.md` | tracked plan artifacts; `15-tracking.sh` gates their shape, `substrate audit` executes their oracles |
| `docs/contracts.md` | THE reference: every contract, hatch, and exit-code rule |

## Reading order

1. [daily-workflow.md](daily-workflow.md) — the loop you actually run.
2. [working-with-the-gate.md](working-with-the-gate.md) — reading failures and fixing them.
3. [adding-a-profile.md](adding-a-profile.md) — the profile contract end to end.
4. [extending-the-framework.md](extending-the-framework.md) — new checks, new hooks, new repos.

## Fast start

```sh
substrate bootstrap --profile go,python --checkpoint --accept-baseline
substrate doctor                     # toolchain + config sanity
substrate selftest                   # negative battery: prove the gate can go red
substrate report                     # advisory maintenance queue (never fails)
```
