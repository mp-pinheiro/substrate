# Version Control Workflow

This repo is a **colocated [Jujutsu](https://jj-vcs.github.io/jj/) + git** repository: `jj` is
the primary interface and a real `.git/` directory sits alongside `.jj/`. Plain `git` still
works for **reading** (`log`/`status`/`diff`/`show`), but a hook (`.substrate/hooks/enforce-jj.sh`)
blocks mutating git — every VCS change goes through jj.

> Git's `HEAD` is left **detached** on purpose — jj drives the working copy, so there is no
> checked-out git branch. Don't `git push`; use `jj git push`.

**The jj mindset.** `@` (the working copy) is snapshotted continuously; commit early and often
with `jj commit`, because commits are local, cheap, and fully reversible. Every commit and
operation is a point you can travel back to (`jj op log`, `jj undo`). Never hoard finished work
in an uncommitted `@` — a step you didn't commit is a restore point you don't have. Committing
is free and local; **pushing** (`jj git push`) is the only step that seals anything to a remote.

## One-time user config

Set once per machine with `jj config edit --user` (`~/.config/jj/config.toml`):

```toml
[revset-aliases]
# Protect already-pushed history: rewriting a commit that is on a remote breaks PRs,
# so treat every remote bookmark as immutable (jj will refuse to rebase it).
'immutable_heads()' = 'builtin_immutable_heads() | remote_bookmarks()'

[aliases]
# `jj tug`: advance the nearest bookmark (e.g. main) to your latest finished change.
tug = ['bookmark', 'advance', '--to', '@-']
```

`jj b` is a built-in shorthand for `jj bookmark`.

**This repo also enables auto-advance for `main`** — repo-scoped, applied via:

```
jj config set --repo experimental-advance-branches.enabled-branches '["main"]'
```

With it, `main` follows every `jj commit` / `jj new` automatically (Git-style), so trunk work
is just `jj commit` then `jj git push` — no manual `jj tug`. `jj tug` stays the tool for feature
bookmarks, which are deliberately *not* auto-advanced.

## Model: trunk-based on `main`

- `main` is a **bookmark** (jj's word for a branch), not a moving `HEAD`, configured to
  **auto-advance** on `jj commit` / `jj new`, so it tracks your latest finished change with no
  manual step (it also follows commits rewritten by `jj rebase` or amend).
- Work lands directly on `main`. Use a feature bookmark only when you want a PR/review.
- Keep the remote in sync: push after finishing a change.

## The change cycle

jj has no staging area — edits are snapshotted continuously into `@`. A fresh empty `@` with
"no description set" is normal; it is where your next edits go. Commit each finished step as you
go — not once at the end:

```
# edit files for one logical step — `jj status` / `jj diff` show what's in @
jj commit -m "type: subject"      # finalize this step; main auto-advances to it
```

Messages **must be [Conventional Commits](https://www.conventionalcommits.org)** —
`type(scope): subject` (`feat`, `fix`, `docs`, `refactor`, `perf`, `test`, `build`, `ci`,
`chore`, `revert`; append `!` for a breaking change). A PreToolUse hook rejects `jj commit` /
`describe` / `squash` messages that don't match.

Use path-scoped `jj commit <files> -m "…"` to split unrelated changes sitting together in `@`.

Those commands are for a human shell. OMP and Claude agents finish owned work through `substrate checkpoint`; their enforcement blocks a direct `jj commit` and lets the checkpoint gate, tighten, and commit the exact owned paths. Kit maintenance uses the same boundary: `substrate bootstrap --checkpoint` and `substrate update --apply --checkpoint` create their own path-scoped local commits while leaving unrelated `@` changes in place. Neither path pushes.

When work is ready to leave your machine:

```
jj push                           # guarded: exact receipt or gate, then push main
jj git push                       # low-level transport; guarded only inside an agent harness
```

`jj push` is a substrate-installed alias (`substrate init` wires it per clone): it calls the
receipt-aware push guard and delegates to `jj git push` only when green. OMP and Claude
intercept a direct agent-issued `jj git push` with the same guard. jj itself exposes no native
push hook (jj-vcs/jj#403), so a direct command from an unsupervised shell is outside that
interception; use `jj push`.

If a push ever says **"Nothing changed"**, `main` didn't move — advance it by hand with
`jj tug` (= `jj bookmark advance --to @-`) and re-push. That should only happen for feature
bookmarks.

## Navigating through time (jj's core power)

| To … | Do |
|------|----|
| See every operation (incl. auto-snapshots), newest first | `jj op log` |
| Undo the last operation | `jj undo` |
| Rewind the **whole repo** to a past operation | `jj op restore <op-id>` |
| Inspect the commit graph | `jj log` |
| Amend an earlier commit in place | `jj edit <rev>` |
| Start a new change on top of any commit | `jj new <rev>` |
| Pull specific files from another revision into `@` | `jj restore --from <rev> [paths]` |
| Drop `@`'s uncommitted edits (reset to parent) | `jj restore` |
| Discard a whole commit | `jj abandon <rev>` |
| Diff any two points | `jj diff --from <rev> --to <rev>` |

`jj op log` + `jj op restore` is the safety net: any botched change is one command from being
rewound, **provided the good state was committed**.

## Sending a PR instead of committing to main

```
jj git push -c @-              # -c/--change; auto-names a bookmark (e.g. push-xyz)
gh pr create --head push-xyz

# or a named bookmark:
jj bookmark set my-feature -r @-
jj git push --bookmark my-feature
```

Address review comments by adding a commit on top, then `jj tug` (or
`jj bookmark set my-feature -r @-`) and `jj git push` again. Because pushed bookmarks are
immutable (config above), you won't accidentally rewrite them.

## Updating from the remote (there is no `git pull`)

```
jj git fetch
jj rebase -d main             # move your in-progress work onto the updated main
```

## Gotchas

- If jj reports a non-tracking `main@origin`, run once: `jj bookmark track main --remote=origin`.
- `jj undo` reverts the last jj operation — the safety net for a botched move or rebase.
- Read-only git (`log`/`status`/`diff`/`show`) and release `git tag` / `git push origin vX.Y.Z`
  stay allowed by the hook; everything else mutating goes through jj.
- **Line endings (repo-specific).** jj does not honor `.gitattributes` (jj-vcs/jj#53), and this
  repo marks `wsl-mounts/*.{bat,vbs,ps1}` as `text eol=crlf`. Without help, jj reads the CRLF
  worktree, compares it to the LF blob git stores, and reports those files permanently modified —
  and a `jj commit` would bake CRLF into the blobs, fighting `.gitattributes`. So this repo sets
  `working-copy.eol-conversion = "input"`, which makes jj check those files in as LF, matching
  git. Caveat: `input` does not convert on the way out, so if jj ever *materializes* those files
  (`jj restore`, checking out an older rev) they land on disk as LF. `git status` flags it;
  `git checkout -- wsl-mounts/` puts CRLF back. Do not use `input-output` — it is repo-wide and
  would rewrite every Linux dotfile (`.zshrc`, `bootstrap.sh`) to CRLF.
- **The repo-scoped config is machine-local.** jj keeps `--repo` settings in
  `~/.config/jj/repos/<hash>/config.toml`, not inside `.jj/`, so neither the auto-advance nor the
  EOL setting travels with a clone. Re-apply both after cloning this repo elsewhere.

## Cheat sheet

| Task | Command |
|------|---------|
| Working-copy status | `jj status` |
| History (graph) | `jj log` |
| Finalize a change | `jj commit -m "…"` |
| Advance trunk to your change | automatic on commit (else `jj tug`) |
| Push trunk (gated) | `jj push` |
| Push a PR branch | `jj git push -c @-` |
| Fetch from remote | `jj git fetch` |
| Undo last jj op | `jj undo` |
| Operation log (time-travel) | `jj op log` |
| Rewind repo to a past op | `jj op restore <op-id>` |
| Amend an earlier commit | `jj edit <rev>` |
