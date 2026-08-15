# Contributing

Contributions are welcome through GitHub issues and pull requests. Report vulnerabilities through the private process in [`SECURITY.md`](SECURITY.md), not a public issue.
Participation in project spaces is governed by the [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md).

## Set up the kit

Substrate currently targets Linux. Install the tools reported by `bin/substrate doctor`, then run:

```sh
git clone https://github.com/mp-pinheiro/substrate.git
cd substrate
bin/substrate bootstrap
just gate
```

The canonical remote is `https://forgejo.yfrit.com/mpp/substrate`; this GitHub repository is a
read-only mirror of `main`.

## Make a change

- Keep each change focused on one problem.
- Edit canonical files under `core/`, `profiles/`, `agents/`, or `skills/`. Do not hand-edit their managed copies under `.substrate/`, `.claude/`, or `.omp/`.
- Run `bin/substrate bootstrap` after changing canonical managed assets.
- Add a profile only when it has a failing fixture and an oracle that proves the profile's own check rejects it. See [`guides/extending-the-framework.md`](guides/extending-the-framework.md).
- Do not weaken a gate, exclusion, protected path, or baseline to hide a finding. Every accepted regression carries a mandatory reason committed to `substrate-baseline.json` and reviewed in the pull request diff.

## Verify the change

Always run the gate:

```sh
just gate
```

Run the relevant end-to-end path as well:

```sh
just battery                  # every suite, concurrent (~85s)
just battery --only <suite>   # just the suites covering your change
bin/substrate selftest        # gate and escape-hatch changes
test/matrix.sh <profile>      # one profile
test/matrix.sh                # changes shared by every profile
```

Match the proof to the change: docs-only needs `just gate`; a single file needs the suites that cover it; the full battery belongs on the landing commit. `bin/substrate audit` takes ~32 minutes and is for landing a plan, not routine verification.

Include the commands and results in the pull request. CI repeats the gate, every profile matrix, the hostile-home oracle, and the tracked plan audit.
