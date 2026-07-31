# Adding a Profile

A profile is one language/stack unit: file claims, checks, templates, fixtures. The schema is in [`docs/contracts.md`](../docs/contracts.md#profilejson-profilesnameprofilejson-repo-local-profiles-in-reposubstrate-profilesname); this page is the build order. The matrix enforces every step — you cannot half-add a profile.

## The five steps

1. **Create `profiles/<name>/profile.json`** (kit) or `substrate-profiles/<name>/profile.json` (repo-local): `claims` mapping each extension to its comment-gate mode (`ast` when an ast-grep grammar exists, `line` with `markers` otherwise, `exempt` when another tool owns the type), `toolchain` (+ install hint per bin), `ci` install lines, `templates`, `checks`.
2. **Write checks** in `profiles/<name>/checks.d/NN-name.sh` (60–79 range). Contract: `source "$SUBSTRATE_DIR/gate-lib.sh"`, files via the inventory collectors, tools via `require_bin_ci <bin> <hint>` (skip locally, fatal in CI), tool breakage via `die_infra` — never pass blind. Exit 0 pass, 1 findings (every line `file:line — problem — fix`), >=2 infra. Copy an existing profile check's shape instead of inventing one.
3. **Ship fixtures**: `fixtures/slop.<ext>` (exactly one slop comment — selftest injects it and requires red) and one `fixtures/bad-*` per check, paired in `check_fixtures`: `[{"file": "fixtures/bad-x.ext", "fails": "NN-name.sh"}]`. A check without a fixture that proves it fires does not ship.
4. **Pin determinism**: templates carry the tool config; the check passes it explicitly (repo config, vendored template by absolute path, or the tool's isolation flag). No bare invocations — user-global config must never influence verdicts. Templates install at init only when `dest` is absent; repo edits win forever after.
5. **Run the matrix cell**: `test/matrix.sh <name>` — scratch repo, init, green baseline, full selftest, then each `check_fixtures` entry injected must turn the gate red with the check named:

```
[ok] matrix <name>: own-check oracle: NN-name.sh rejected bad-x.ext
```

Skipping a step fails deterministically:

```
[XX] matrix <name>: init failed                        (corrupt profile.json, duplicate claims)
[XX] matrix <name>: selftest failed                    (missing/ineffective slop fixture)
[XX] matrix <name>: checks without check_fixtures      (oracle-less check)
[XX] matrix <name>: gate stayed green with bad-x.ext   (check does not fire)
```

## Writing the check body

Non-negotiables (gate- or matrix-enforced):

- **Fail closed**: `require_bin_ci` for optional-locally tools; `die_infra` on any tool malfunction.
- **File selection from the inventory**, never by globbing the tree — submodules and unclaimed files are excluded by contract.
- **Comment discipline applies to your check itself**: max 2 consecutive comment lines; no narration.
- **shellcheck -S warning clean**; bash + jq + coreutils only, no sed/awk.

## Testing it

```sh
test/matrix.sh <name>       # the whole contract, including your negative oracles
substrate doctor            # toolchain hints for anyone missing the tools
```

Then wire CI: the profile's `ci` lines are injected into the workflow toolchain step at init in consumer repos.
