# substrate

Deterministic quality gates for agentic development, installable in any repo. Rules live in tools that reject bad changes — at write time (harness hooks), commit/push time, and merge time (gate + CI) — because prompt instructions decay and models imitate whatever the tree already contains.

Born from a working prototype in a dotfiles repo; every design rule here was bought with a real failure there. The full rationale: [`docs/contracts.md`](docs/contracts.md).

## Install the kit

```sh
git clone <this repo> ~/git/substrate
export PATH="$HOME/git/substrate/bin:$PATH"
```

## Scaffold a repo

```sh
cd ~/your/repo
substrate init --profile go            # or: python,airflow  ts: typescript,svelte  etc.
substrate doctor                       # toolchain + config sanity
substrate gate                         # first run: findings + pending baseline
substrate baseline                     # grandfather current debt (green infra only)
# positive control: add "# now we check the thing" to a source file — gate MUST go red; revert
substrate selftest                     # full negative battery
```

What lands in the repo: `.substrate/` (vendored, pinned core — tracked), `substrate.json` (config: profiles, the reviewed `unscanned` ledger, budgets, protected paths), `substrate-baseline.json` (grandfathered debt; only the gate writes it), hooks wired for Claude Code (`.claude/settings.json`) and omp (`.omp/extensions/`), a CI workflow, and a `just gate` recipe.

## What the gate enforces

| Check | Rejects |
| --- | --- |
| unclaimed-source | tracked files no profile claims and the ledger doesn't sanction — silence is a decision |
| comments | comment slop (narration, restating, banners, TODO chatter) via AST-backed detection; per-file ratchet |
| duplication | copy/paste growth (jscpd) vs baseline |
| budgets | file-size growth vs baseline; hard cap configurable |
| data-validity | JSON/YAML that does not parse |
| gitleaks | secrets in git history |
| profile checks | language toolchain findings (shellcheck, ruff, golangci-lint, sqlfluff, tflint, tsc, ...) |
| vendor-drift (kit repo) | `.substrate/` diverging from `core/` |

Everything fails closed: a broken or missing detector is a red gate ("cannot pass blind"), never a silent skip. Ratchets only tighten; loosening requires `--accept-regression` and prints the diff. Escape hatches are line-scoped markers (`gate:allow-comment`, `gate:allow-*`) plus the `unscanned` ledger — all diff-visible.

## Profiles

`base` (always on: YAML/JSON claims) plus per-language profiles under [`profiles/`](profiles/). Each declares its claims (extension → comment-gate mode), toolchain, CI install lines, config templates, checks, and fixtures. Every profile is proven by [`test/matrix.sh`](test/matrix.sh): scratch repo → init → baseline → selftest (slop fixtures must go red) → own-check oracles (bad fixtures must be rejected *by the profile's own checks*). A profile without oracles does not ship.

## Developing the kit

```sh
just gate            # the kit gates itself (including vendor drift)
bin/substrate selftest
test/matrix.sh       # every profile, scratch-repo oracle
```

## Account pin (this repo lives under the work org)

Fresh clone: `cp .env.example .env`. The zsh dotenv plugin exports
`GH_CONFIG_DIR` on cd, so `gh` in this repo uses the secondary account while the
global active account is never touched. Seed the pinned dir once with a fresh
login (never by copying the personal config):

    export GH_CONFIG_DIR=~/.config/gh-secondary
    gh auth login    # secondary-user only; this dir never sees the personal token

Re-auth after token rotation the same way — WITH the pin set — or the pinned
dir goes stale while the global one updates.

Pushes don't use tokens at all: the gitdir-scoped include in `~/.gitconfig`
loads `.gitconfig-secondary`, whose insteadOf rewrites origin to the
`github-secondary` SSH key. Verify with: `git ls-remote --get-url origin`.
