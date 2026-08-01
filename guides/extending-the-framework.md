# Extending the Framework

How to add checks and hooks without weakening the system, and how the kit lands in new repos. These design rules were each bought with a real failure — treat them as load-bearing. Canonical statement: [`docs/contracts.md`](../docs/contracts.md#design-rules-inherited-from-the-dotfiles-prototype-each-bought-with-a-failure).

## Design rules

1. **Fail closed.** A detector that breaks must fail the gate, never read as "no findings". Exit `1` = findings, `>=2` = infrastructure failure; the runner fails the gate with `cannot pass blind`. Never `2>/dev/null` a detector; missing tools warn-skip locally only where CI is guaranteed to run the check (`require_bin_ci`).
2. **Block-and-report, never silently mutate.** Hooks reject with the offending lines and the fix; they do not rewrite the agent's output. The rejection message is a prompt — write it so the reader knows exactly what to do instead.
3. **Ratchet, don't absolutize.** Brownfield debt gets grandfathered in `substrate-baseline.json`; only regressions fail. The writer refuses on a red gate; loosening requires `--accept-regression` and prints the diff.
4. **Escape hatches are line-scoped and visible in diffs** (`gate:allow-*` markers, the `unscanned` ledger). Never add a config-wide off switch.
5. **Negative tests are mandatory.** A check ships with its oracle: `check_fixtures` pairs a bad file with the check that must reject it; `test/matrix.sh` proves the pairing in a scratch repo; `substrate selftest` proves slop injection, broken-tool, and corrupt-baseline all go red. A gate verified only on the green path is decoration.
6. **Both harnesses, always.** Any write-time policy lands in `core/hooks/*.sh` (Claude Code, via `core/claude-hooks.json`) AND `core/omp/substrate-quality.ts` (omp). One without the other is a hole.
7. **Determinism.** No user-global tool config may influence verdicts — pin configs explicitly. No sed/awk; bash + jq + coreutils; config is JSON only.

## Adding a check

Where it lives decides who gets it:

- `core/checks.d/NN-name.sh` (05–59) — every repo.
- `profiles/<name>/checks.d/NN-name.sh` (60–79) — repos with the profile ([adding-a-profile.md](adding-a-profile.md)).
- `<repo>/checks.d/NN-name.sh` (80–99) — one repo; vendored by `substrate bootstrap`.

Skeleton — copy an existing check's shape:

```sh
#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=../gate-lib.sh
source "$SUBSTRATE_DIR/gate-lib.sh"

require_bin_ci mytool "install: https://..." || exit 0
out=$(mytool --pinned-config "$SUBSTRATE_DIR/profiles/x/templates/cfg" ...) || die_infra "mytool failed — the gate cannot pass blind"
[ -z "$findings" ] || { printf '%s\n' "$findings"; exit 1; }
metric myratchet "$value"
exit 0
```

Ratcheted measurements: `metric <name> <value>` (lower is better). The runner compares against the baseline — regression fails, improvement prints a lock-in hint. Per-file ratchets are namespaced metrics: `metric "comments:src/x.go" 2`.

Then: pair a fixture (`check_fixtures` for profiles; a selftest/matrix assertion for core), run the negative battery, re-baseline on a green run.

## Adding a write-time policy

Path protection: a `case` arm in `core/hooks/protect-paths.sh` and its mirror entry in `core/omp/substrate-quality.ts`. Both match the resolved realpath; symlink writes are blocked outright — that rule exists because a write through a symlinked doc destroyed its target once. Smoke it by piping hook JSON manually:

```sh
echo '{"tool_input":{"file_path":"substrate-baseline.json"}}' | .substrate/hooks/protect-paths.sh; echo $?
```

Kit changes reach consumer repos via `substrate bootstrap`. Never edit `.substrate/` directly; `80-vendor-drift.sh` catches drift.

## Bootstrapping a repo

```sh
substrate bootstrap --profile a,b
```

The first run vendors the engine, seeds `substrate.json`, copies absent templates, installs managed CI workflows, wires both harnesses, synchronizes kit-owned agents and skills, and installs the gate recipes. Later runs read the profile list from `substrate.json` and synchronize Substrate-owned files with `substrate bootstrap`; same-name repo-owned agents and skills remain untouched.

1. `substrate doctor` — toolchain.
2. `.substrate/gate.sh` — first run: findings + pending baseline.
3. Get green on **mechanics** first, then `--update-baseline` once to grandfather real debt. Never initialize from a red-for-infrastructure run.
4. Positive control: add a slop comment, rerun, MUST go red; revert.
5. `substrate selftest`.

Repo-specific design work: the contract check (schema/codegen drift), boundaries (import-linter / dependency-cruiser / depguard), and which debts to ratchet vs fix.

## Gotchas ledger (paid for, do not rediscover)

- jaq (`jq` on some machines): `jq -s` across two files can yield `null` for the second — merge with single-input `--argjson` instead.
- Bash `${var:-{}}` appends a literal `}` when `var` is set. Never inline `{}` defaults for JSON; normalize in a separate statement.
- `set -o pipefail` + `| head -N` sends SIGPIPE to the producer — cap inside jq (`.[0:10]`), not with a pipe.
- zsh has no tree-sitter grammar: `line` mode is the only sanctioned AST fallback.
- ast-grep via `bunx` prints deprecation noise on the `sg` alias; prefer the `ast-grep` binary (CI installs it globally).
