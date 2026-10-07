# substrate

Deterministic quality gates for agentic development, installable in any repo. Rules live in tools that reject bad changes — at write time (harness hooks), commit/push time, and merge time (gate + CI) — because prompt instructions decay and models imitate whatever the tree already contains.

Born from a working prototype in a dotfiles repo; every design rule here was bought with a real failure there. The full rationale: [`docs/contracts.md`](docs/contracts.md).

This project is not affiliated with Parity Technologies or its Substrate blockchain framework.

## Install the kit

```sh
go install github.com/mp-pinheiro/substrate/cmd/substrate@latest
```

The binary carries the whole kit (`bin/`, `core/`, `profiles/`, `skills/`, `agents/`) and materializes it
on first use under `${XDG_CACHE_HOME:-~/.cache}/substrate/kit/<version>-<digest>`; consumers need no kit
clone. `SUBSTRATE_KIT_CACHE` relocates that directory (use it when the default cache is mounted `noexec`).
The same binary answers to `substrate-engine` when invoked under that name, and the first CLI run drops a
`substrate-engine` symlink beside itself so installed Git hooks, `just gate`, and CI find the engine on
`PATH` without a second install. It skips that symlink when another `substrate-engine` is already on
`PATH`, so a kit checkout's engine is never shadowed.

### One machine, many kit versions

Every engine command except `version`, `pin`, `capabilities` and `maintenance` first reads the nearest
`.substrate/vendor.json` and hands off to an engine that repository accepts: the exact version for `trunk`
and `worktree` vendoring, `<version>+release`, `+nightly` or `+module` for published kits. Whichever
`substrate-engine` a hook, Git hook, shell or harness launches, the command runs on the engine the
repository pins.

- A matching `substrate-engine` elsewhere on `PATH` wins.
- Otherwise a published kit's engine is downloaded once from the GitHub release (the public mirror;
  the Forgejo host needs credentials), checked against `SHA256SUMS` and its own `version`, and cached
  under `${XDG_CACHE_HOME:-~/.cache}/substrate/engines/<version>`. `SUBSTRATE_ENGINE_CACHE` relocates the
  cache and `SUBSTRATE_RELEASE_BASE_URL` the download origin.
- If no matching engine can be found or verified, a published-kit repository stops with exit 12 before the
  command runs. A `trunk` or `worktree` repository warns and continues on the running engine, so
  `substrate update` can still re-vendor it; its gate reports the mismatch.

`maintenance` always runs on the engine that invoked it, because an update must run the new kit against a
repository that still pins the old one. A `substrate-engine` symlink left beside a `go install`ed binary by
a release older than this behavior can still shadow a kit checkout; delete it once.

Working on the kit itself still wants a checkout:

```sh
git clone https://github.com/mp-pinheiro/substrate.git ~/git/substrate
export PATH="$HOME/git/substrate/bin:$PATH"
```

The canonical remote is `https://forgejo.yfrit.com/fairfruit/substrate`; this GitHub repository is a
read-only mirror of `main`.

## Release channels

Stable releases are tagged `vX.Y.Z`. Nightlies are pre-releases cut at 07:00 UTC from a green revision and pruned after 14 days; once `vX.Y.Z` has shipped they are tagged against the next minor (`vX.Y+1.0-nightly.YYYYMMDD`) so a nightly always sorts above the stable it builds on. The scheduled run skips when the revision's tree is identical to the most recent nightly tag reachable from it, so a night without changes cuts nothing; a manually dispatched nightly is always cut.

Maintainers cut a stable release with `just bump major|minor|patch` from a clean working copy on `main`. The command updates `VERSION`, rebuilds and repins the engine, re-vendors the kit in one guarded operation, commits the result as `chore(release): vX.Y.Z`, and pushes `main` through the gated push. Landing that version change on Forgejo `main` starts the stable release workflow; publication waits for the gate status on the same revision. The workflow publishes neither from a red gate nor from an unbumped revision.

```sh
go install github.com/mp-pinheiro/substrate/cmd/substrate@latest                  # newest stable
go install github.com/mp-pinheiro/substrate/cmd/substrate@v0.2.0-nightly.20260920 # a nightly
```

Each release also carries `substrate_<version>_linux_{amd64,arm64}.tar.gz` (containing `substrate` plus a
`substrate-engine` symlink) and `SHA256SUMS`, downloadable from the Forgejo release page or
`https://github.com/mp-pinheiro/substrate/releases`.

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
Repositories whose CI is managed elsewhere set `"ci": { "provider": "external" }` in `substrate.json`. Bootstrap then leaves `.github/` ungenerated, removes only workflows marked `# substrate-managed`, and expects the repository pipeline to invoke the same `substrate-engine gate` or `just gate`; external CI is not an enforcement opt-out.

Run `substrate bootstrap --checkpoint` again whenever the kit or repository scaffold changes. Use `substrate update --apply --checkpoint` when only the vendored engine should change.

Repository maintenance is transactional. `bootstrap`, `init`, and `update --apply` capture the current revision and dirty paths, render the requested state in a scratch clone, record that scratch Git candidate's seed commit as the pending-scan boundary, gate that candidate, and then replace only the declared managed units. Dirty Substrate-owned paths stop the transaction unless a prior receipt or ownership marker authorizes repair. Without `--checkpoint`, repo-owned inputs that the installer merges or preserves are copied into the candidate and left uncommitted; checkpoint mode refuses to absorb them. Concurrent drift stops the transaction, and unrelated dirty work stays untouched.

`--checkpoint` tightens an existing baseline after the candidate passes and creates one local Conventional Commit through the active Git or jj repository. Initial debt still requires the explicit `--accept-baseline` flag. An interrupted apply or exact-path commit records resumable state under the repository's VCS metadata; rerun the same command to finish it. Repository runtime wiring and user-harness synchronization run after the repository commit and report their own status. `--repo-only` skips the user phase, `--json` prints the receipt, and no maintenance command pushes.

What lands in the repo: `.substrate/` (vendored, pinned core), `substrate.json` (profiles, reviewed exclusions, budgets, protected and ask paths), `substrate-baseline.json` (grandfathered debt; only the gate writes it), Claude and omp hooks, `.omp/lsp.json` (seeded once from active profile declarations), managed agents and skills for both harnesses, managed CI workflows, and a `just gate` recipe. Agent and skill roots carrying `.substrate-managed.json` are fully kit-owned and converge exactly; unmarked same-name assets remain repo-owned.

Agents and skills are optional helpers, not the enforcement layer, and they are repo-scoped: `substrate init` installs them into a governed repository's `.claude/` and `.omp/`, and the user harness carries no copy of them — a helper that named the gate from every unrelated repository would be instruction noise where nothing enforces it. Omp enforcement comes from the automatically loaded user-scoped `substrate-quality.ts` extension and its private modules: it injects gate policy, tracks agent-owned paths, blocks protected operations and direct commits, scans every mutating tool result (including LSP refactors), and refuses task completion until the agent runs a green local `substrate_checkpoint`. The checkpoint tightens improved ceilings, commits only owned paths, and records an exact-state receipt; it never pushes. `substrate doctor` and `/substrate` expose the installed and loaded path, aggregate source hash, engine version, and latest lifecycle state.

## Editor feedback

Profiles may declare optional language servers for omp. `substrate bootstrap` seeds `.omp/lsp.json` from the active profiles only when the file does not exist; later runs preserve repository edits. `substrate doctor` reports whether each server binary is available and prints an installation hint when it is missing. Substrate does not install LSP binaries, and a missing server disables inline diagnostics without failing the gate.

Profile mappings currently cover YAML/JSON, C++, Go, Lua, Python, shell, Svelte, Terraform, and TypeScript. Each mapping names the server binary and gives an installation hint.

## What the gate enforces

| Check | Rejects |
| --- | --- |
| unclaimed-source | tracked files no profile claims and the ledger doesn't sanction — silence is a decision |
| comments | comment slop (narration, restating, banners, TODO chatter) via AST-backed detection; per-file ratchet |
| duplication | copy/paste growth (jscpd) vs baseline |
| budgets | new files over the per-file line target; the count of oversized files is ratcheted |
| data-validity | JSON/YAML that does not parse |
| gitleaks | secrets in pending Git/jj work; full reachable history is explicit (`gate --deep`) and CI-owned |
| profile checks | language toolchain findings (shellcheck, ruff, golangci-lint, sqlfluff, tflint, tsc, ...) |
| vendor-drift (kit repo) | `.substrate/` diverging from `core/` |

Everything fails closed: a broken or missing detector is a red gate ("cannot pass blind"), never a silent skip. `budgets.max_file_lines` is a per-file line target (the generated default is 500) and never fails the gate by itself; the ratcheted debt metric is `oversized_files`, the count of claimed files above the target, so legacy files are grandfathered by the baseline and each new oversized file is red. `metric` (lower is better) and `metric_hi` (higher is better, e.g. coverage) are the other ratchets. `max_file_lines` is reported but never persisted in the baseline and cannot be accepted with `--accept-regression`; accept `oversized_files` instead, or change the target through a reviewed `substrate.json` policy change. `--tighten` (used by every checkpoint) tightens ratchets component-wise and prunes legacy budget keys. Escape hatches are line-scoped markers (`gate:allow-comment`, `gate:allow-*`), the `unscanned` ledger, `checks.config` (per-check runtime overrides), and `scopes`.

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