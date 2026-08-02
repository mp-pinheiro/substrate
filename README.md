# substrate
[![substrate gate](https://github.com/mp-pinheiro/substrate/actions/workflows/substrate-gate.yml/badge.svg)](https://github.com/mp-pinheiro/substrate/actions/workflows/substrate-gate.yml)

Deterministic quality gates for agentic development, installable in any repo. Rules live in tools that reject bad changes — at write time (harness hooks), commit/push time, and merge time (gate + CI) — because prompt instructions decay and models imitate whatever the tree already contains.

Born from a working prototype in a dotfiles repo; every design rule here was bought with a real failure there. The full rationale: [`docs/contracts.md`](docs/contracts.md).

This project is not affiliated with Parity Technologies or its Substrate blockchain framework.

## Install the kit

```sh
git clone https://github.com/mp-pinheiro/substrate.git ~/git/substrate
export PATH="$HOME/git/substrate/bin:$PATH"
```

## Requirements

Substrate currently supports Linux. It expects Bash, Git, `jq`, `yq`, Bun, and gitleaks; profile-specific tools vary. Run `substrate doctor` for the exact dependencies required by the selected profiles. Jujutsu is optional.

## Scaffold a repo

```sh
cd ~/your/repo
substrate bootstrap --profile go       # or: python,airflow  ts: typescript,svelte  etc.
substrate doctor                       # toolchain + config sanity
substrate gate                         # first run: findings + pending baseline
substrate baseline                     # grandfather current debt (green infra only)
# positive control: add "# now we check the thing" to a source file — gate MUST go red; revert
substrate selftest                     # full negative battery
```

Run `substrate bootstrap` again whenever the kit changes. Existing repositories read their profiles from `substrate.json`; the command refreshes only explicitly Substrate-owned files and fails incomplete when required hooks or destinations cannot be installed safely.

What lands in the repo: `.substrate/` (vendored, pinned core), `substrate.json` (profiles, reviewed exclusions, budgets, protected paths), `substrate-baseline.json` (grandfathered debt; only the gate writes it), Claude and omp hooks, `.omp/lsp.json` (seeded once from active profile declarations), managed agents and skills for both harnesses, managed CI workflows, and a `just gate` recipe. Agent and skill roots carrying `.substrate-managed.json` are fully kit-owned and converge exactly; unmarked same-name assets remain repo-owned.

Agents and skills are optional helpers, not the enforcement layer. Omp enforcement comes from the automatically loaded `substrate-quality.ts` extension: it injects the gate policy into the main agent, blocks protected operations, scans mutating tool results (including LSP refactors), and runs the full gate before a push.

## Editor feedback

Profiles may declare optional language servers for omp. `substrate bootstrap` seeds `.omp/lsp.json` from the active profiles only when the file does not exist; later runs preserve repository edits. `substrate doctor` reports whether each server binary is available and prints an installation hint when it is missing. Substrate does not install LSP binaries, and a missing server disables inline diagnostics without failing the gate.

Profile mappings currently cover YAML/JSON, C++, Go, Lua, Python, shell, Svelte, Terraform, and TypeScript. Each mapping names the server binary and gives an installation hint.

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

`base` (always on: YAML/JSON claims) plus per-language profiles under [`profiles/`](profiles/). Each declares its claims (extension → comment-gate mode), toolchain, CI install lines, optional LSP mappings, config templates, checks, and fixtures. Every profile is proven by [`test/matrix.sh`](test/matrix.sh): scratch repo → init → baseline → selftest (slop fixtures must go red) → own-check oracles (bad fixtures must be rejected *by the profile's own checks*). A profile without oracles does not ship.

## Developing the kit

```sh
just gate            # the kit gates itself (including vendor drift)
bin/substrate selftest
test/matrix.sh       # every profile, scratch-repo oracle
```

## Contributing and security

See [`CONTRIBUTING.md`](CONTRIBUTING.md) before opening a pull request. Report vulnerabilities privately as described in [`SECURITY.md`](SECURITY.md).

## License

Substrate is licensed under the [GNU General Public License v3.0 only](LICENSE).