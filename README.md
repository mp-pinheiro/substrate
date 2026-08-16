# substrate

Deterministic quality gates for agentic development, installable in any repo. Rules live in tools that reject bad changes — at write time (harness hooks), commit/push time, and merge time (gate + CI) — because prompt instructions decay and models imitate whatever the tree already contains.

Born from a working prototype in a dotfiles repo; every design rule here was bought with a real failure there. The full rationale: [`docs/contracts.md`](docs/contracts.md).

This project is not affiliated with Parity Technologies or its Substrate blockchain framework.

## Install the kit

```sh
git clone https://github.com/mp-pinheiro/substrate.git ~/git/substrate
export PATH="$HOME/git/substrate/bin:$PATH"
```

The canonical remote is `https://forgejo.yfrit.com/mpp/substrate`; this GitHub repository is a
read-only mirror of `main`.

## Requirements

Substrate currently supports Linux. It expects Go (to build `substrate-engine`), Bash, Git, `jq`, `yq`, Bun, and gitleaks; profile-specific tools vary. Run `substrate doctor` for the exact dependencies required by the selected profiles. Jujutsu is optional.

## Scaffold a repo

```sh
cd ~/your/repo
substrate bootstrap --profile go --checkpoint --accept-baseline
substrate doctor                       # toolchain + config sanity
# positive control: add "# now we check the thing" to a source file — gate MUST go red; revert
substrate selftest                     # full negative battery
```

Run `substrate bootstrap --checkpoint` again whenever the kit or repository scaffold changes. Use `substrate update --apply --checkpoint` when only the vendored engine should change.

Repository maintenance is transactional. `bootstrap`, `init`, and `update --apply` capture the current revision and dirty paths, render the requested state in a scratch clone, gate that candidate, and then replace only the declared managed units. Dirty Substrate-owned paths stop the transaction unless a prior receipt or ownership marker authorizes repair. Without `--checkpoint`, repo-owned inputs that the installer merges or preserves are copied into the candidate and left uncommitted; checkpoint mode refuses to absorb them. Concurrent drift stops the transaction, and unrelated dirty work stays untouched.

`--checkpoint` tightens an existing baseline after the candidate passes and creates one local Conventional Commit through the active Git or jj repository. Initial debt still requires the explicit `--accept-baseline` flag. An interrupted apply or exact-path commit records resumable state under the repository's VCS metadata; rerun the same command to finish it. Repository runtime wiring and user-harness synchronization run after the repository commit and report their own status. `--repo-only` skips the user phase, `--json` prints the receipt, and no maintenance command pushes.

What lands in the repo: `.substrate/` (vendored, pinned core), `substrate.json` (profiles, reviewed exclusions, budgets, protected paths), `substrate-baseline.json` (grandfathered debt; only the gate writes it), Claude and omp hooks, `.omp/lsp.json` (seeded once from active profile declarations), managed agents and skills for both harnesses, managed CI workflows, and a `just gate` recipe. Agent and skill roots carrying `.substrate-managed.json` are fully kit-owned and converge exactly; unmarked same-name assets remain repo-owned.

Agents and skills are optional helpers, not the enforcement layer. Omp enforcement comes from the automatically loaded user-scoped `substrate-quality.ts` extension and its private modules: it injects gate policy, tracks agent-owned paths, blocks protected operations and direct commits, scans every mutating tool result (including LSP refactors), and refuses task completion until the agent runs a green local `substrate_checkpoint`. The checkpoint tightens improved ceilings, commits only owned paths, and records an exact-state receipt; it never pushes. `substrate doctor` and `/substrate` expose the installed and loaded path, aggregate source hash, engine version, and latest lifecycle state.

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
| gitleaks | secrets in pending Git/jj work; full reachable history is explicit (`gate --deep`) and CI-owned |
| profile checks | language toolchain findings (shellcheck, ruff, golangci-lint, sqlfluff, tflint, tsc, ...) |
| vendor-drift (kit repo) | `.substrate/` diverging from `core/` |

Everything fails closed: a broken or missing detector is a red gate ("cannot pass blind"), never a silent skip. Ratchets support both directions — `metric` (lower is better) and `metric_hi` (higher is better, e.g. coverage); `--tighten` (used by every checkpoint) tightens component-wise and garbage-collects orphaned keys. Loosening requires `--accept-regression[=key1,key2] --reason <text>` (justification is committed to the baseline diff) and prints the diff. Escape hatches are line-scoped markers (`gate:allow-comment`, `gate:allow-*`), the `unscanned` ledger, `checks.config` (per-check runtime overrides), and `scopes` (per-path profile restriction) — all diff-visible.

## Profiles

`base` (always on: YAML/JSON claims) plus per-language profiles under [`profiles/`](profiles/). Each declares its claims (extension → comment-gate mode), toolchain, CI install lines, optional LSP mappings, config templates, checks, and fixtures. Every profile is proven by [`test/matrix.sh`](test/matrix.sh): scratch repo → init → baseline → selftest (slop fixtures must go red) → own-check oracles (bad fixtures must be rejected *by the profile's own checks*). A profile without oracles does not ship.

## Developing the kit

```sh
just gate                  # the kit gates itself (including vendor drift)
just battery               # every suite, concurrent, ~85s
just battery --only receipt-test,maintenance-test
bin/substrate selftest
test/matrix.sh             # every profile, scratch-repo oracle
```

`just battery` ([`test/run.sh`](test/run.sh)) shadows `gitleaks` for suites that are not about secret scanning:
it costs ~4.7s of fixed rule compilation per invocation regardless of repo size, and every fixture gate pays it.

## Contributing and security

See [`CONTRIBUTING.md`](CONTRIBUTING.md) before opening a pull request. Report vulnerabilities privately as described in [`SECURITY.md`](SECURITY.md).

## License

Substrate is licensed under the [GNU General Public License v3.0 only](LICENSE).