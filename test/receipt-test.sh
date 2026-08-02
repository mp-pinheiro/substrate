#!/usr/bin/env bash
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"
export BUN_INSTALL="$HOME/.bun"
mkdir -p "$HOME/.bun/install/global/node_modules/@oh-my-pi/pi-coding-agent/dist/types" \
    "$T/repo/.substrate/checks.d" "$T/fake-bin"
printf 'sdk-v1\n' > "$HOME/.bun/install/global/node_modules/@oh-my-pi/pi-coding-agent/dist/types/index.d.ts"
cat > "$T/fake-bin/actionlint" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$T/fake-bin/actionlint"
export PATH="$T/fake-bin:$PATH"

fail() { printf 'receipt-test FAIL: %s\n' "$1" >&2; exit 1; }
expect_valid() {
    gate_receipt_matches || fail "$1 did not restore the exact receipt state"
}
expect_invalid() {
    if gate_receipt_matches; then fail "$1 did not invalidate the receipt"; fi
}

cd "$T/repo" || exit 9
git init -q --initial-branch=main
git config user.name substrate
git config user.email substrate@localhost
printf '{"version":1,"profiles":[],"inventory":"git","unscanned":["*.txt"],"protected_paths":[],"comment":{"allow_tags":[]},"budgets":{"max_file_lines":500},"duplication":{"min_tokens":35},"report":{"max_age_days":14},"checks":{"disabled":[]},"contracts":[]}\n' > substrate.json
printf '{"metrics":{}}\n' > substrate-baseline.json
printf '0.1.0\n' > .substrate/VERSION
printf '#!/usr/bin/env bash\nexit 0\n' > .substrate/checks.d/probe.sh
chmod +x .substrate/checks.d/probe.sh
printf 'tracked\n' > tracked.txt
printf '{"scripts":{"verify":"true"}}\n' > package.json
printf 'lock-v1\n' > bun.lock
git add -A
git commit -qm 'chore: initialize'

REPO_ROOT=$PWD
source "$KIT_ROOT/core/receipt-lib.sh"
commit=$(git rev-parse HEAD)
write_gate_receipt test "$commit" git >/dev/null || fail "initial receipt write failed"
expect_valid "initial state"

printf 'dirty\n' >> tracked.txt
expect_invalid "dirty working tree"
git restore -- tracked.txt
expect_valid "working-tree restore"

git tag receipt-ref
expect_invalid "ref change"
git tag -d receipt-ref >/dev/null
expect_valid "ref restore"

cp substrate.json "$T/substrate.json"
jq '.budgets.max_file_lines = 400' substrate.json > "$T/config.json"
cp "$T/config.json" substrate.json
expect_invalid "configuration change"
cp "$T/substrate.json" substrate.json
expect_valid "configuration restore"

cp .substrate/checks.d/probe.sh "$T/probe.sh"
printf '#!/usr/bin/env bash\nprintf "changed\\n"\n' > .substrate/checks.d/probe.sh
chmod +x .substrate/checks.d/probe.sh
expect_invalid "vendored engine change"
cp "$T/probe.sh" .substrate/checks.d/probe.sh
expect_valid "vendored engine restore"

cp "$T/fake-bin/actionlint" "$T/actionlint"
printf '#!/usr/bin/env bash\nprintf "changed\\n"\n' > "$T/fake-bin/actionlint"
chmod +x "$T/fake-bin/actionlint"
expect_invalid "tool binary change"
cp "$T/actionlint" "$T/fake-bin/actionlint"
expect_valid "tool binary restore"

sdk="$HOME/.bun/install/global/node_modules/@oh-my-pi/pi-coding-agent/dist/types/index.d.ts"
printf 'sdk-v2\n' > "$sdk"
expect_invalid "external SDK change"
printf 'sdk-v1\n' > "$sdk"
expect_valid "external SDK restore"

printf '{"scripts":{"verify":"false"}}\n' > package.json
expect_invalid "package configuration change"
git restore -- package.json
expect_valid "package configuration restore"

printf 'lock-v2\n' > bun.lock
expect_invalid "lockfile change"
git restore -- bun.lock
expect_valid "lockfile restore"

git commit --allow-empty -qm 'chore: advance revision'
expect_invalid "revision change"

printf 'receipt-test: tree, refs, config, engine, toolchain, SDK, lockfile, revision invalidation green\n'
