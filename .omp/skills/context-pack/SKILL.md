---
name: context-pack
description: Build a context-pack artifact for a task in this repo — scope, exact files, contracts, patterns to copy, and non-goals — so implementation can run in a fresh session without re-discovery.
allowed-tools: Bash(jj:*), Bash(git:*), Bash(rg:*), Bash(just:*), Read, Grep, Glob, Write
---

Produce a small, self-contained brief that lets a fresh session implement a task without exploratory reading. Gathering context and implementing are separate sessions; this skill is the gathering half.

# Steps

1. Take the task scope from the user (one sentence). If absent, ask for it.
2. Discover the involved files: `jj file list` (or `git ls-files`) filtered by relevance, plus targeted `rg`. Read only what the task genuinely touches.
3. Read `substrate.json` (active profiles, unscanned ledger, budgets) and `docs/contracts.md` if the kit is vendored here (check contract, ratchet semantics, escape hatches) and note which rules apply to this task.
4. Write the pack to `.pi/plans/<slug>.md` (slug from the scope, kebab-case) with exactly these sections:
   - **Goal** — one paragraph, the observable outcome.
   - **Files in scope** — exact paths, one line each with why.
   - **Contracts** — which profile claims, checks, and gate rules apply (name the file and check).
   - **Pattern to copy** — one concrete exemplar file in this repo that the new code should imitate.
   - **Non-goals** — what must NOT change.
   - **Acceptance** — executable items in the tracked form `- [ ] claim :: verify-command`, always ending with `- [ ] gate green :: substrate gate`.
5. Keep the pack under 60 lines. Print its path.

# Rules

- The pack must be usable with zero conversation history.
- Point to files; never paste file contents into the pack.
- Acceptance items must be machine-checkable: `substrate audit` runs every `:: verify-command` verbatim.
- No implementation in this session.
