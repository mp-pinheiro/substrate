#!/usr/bin/env bash
# Dual-leg oracle (B6): the bash _v1 body and a self-built Go engine (A1/A25)
# share the same gate_receipt_matches/write_gate_receipt call sites (B1's seam).
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/engine-fixture.sh
source "$KIT_ROOT/test/lib/engine-fixture.sh"
engine_fixture_home
engine_fixture_sdk

fail() { printf 'receipt-test FAIL: %s\n' "$1" >&2; exit 1; }
expect_valid() {
    gate_receipt_matches || fail "[$LEG] $1 did not restore the exact receipt state"
}
expect_invalid() {
    if gate_receipt_matches; then fail "[$LEG] $1 did not invalidate the receipt"; fi
}

command -v go >/dev/null 2>&1 || fail "go is required for the go-leg replay"
SUBSTRATE_ENGINE_BIN=$(engine_build fail go "$(cat VERSION)") || exit 1
export SUBSTRATE_ENGINE_BIN

source "$KIT_ROOT/core/receipt-lib.sh"

# shellcheck source=lib/receipt-fixture.sh
source "$KIT_ROOT/test/lib/receipt-fixture.sh"

run_matrix() {
    LEG="$1"
    export SUBSTRATE_ENGINE="$LEG"
    local repo="$T/repo-$LEG" commit
    seed_repo "$repo"
    REPO_ROOT=$PWD
    commit=$(git rev-parse HEAD)
    write_gate_receipt test "$commit" git >/dev/null || fail "[$LEG] initial receipt write failed"
    expect_valid "initial state"

    printf 'dirty\n' >> tracked.txt
    expect_invalid "dirty working tree"
    git restore -- tracked.txt
    expect_valid "working-tree restore"

    git tag receipt-ref
    expect_invalid "ref change"
    git tag -d receipt-ref >/dev/null
    expect_valid "ref restore"

    cp substrate.json "$T/$LEG-substrate.json"
    jq '.budgets.max_file_lines = 400' substrate.json > "$T/$LEG-config.json"
    cp "$T/$LEG-config.json" substrate.json
    expect_invalid "configuration change"
    cp "$T/$LEG-substrate.json" substrate.json
    expect_valid "configuration restore"

    cp .substrate/checks.d/probe.sh "$T/$LEG-probe.sh"
    printf '#!/usr/bin/env bash\nprintf "changed\\n"\n' > .substrate/checks.d/probe.sh
    chmod +x .substrate/checks.d/probe.sh
    expect_invalid "vendored engine change"
    cp "$T/$LEG-probe.sh" .substrate/checks.d/probe.sh
    expect_valid "vendored engine restore"

    cp "$T/fake-bin/actionlint" "$T/$LEG-actionlint"
    printf '#!/usr/bin/env bash\nprintf "changed\\n"\n' > "$T/fake-bin/actionlint"
    chmod +x "$T/fake-bin/actionlint"
    expect_invalid "tool binary change"
    cp "$T/$LEG-actionlint" "$T/fake-bin/actionlint"
    expect_valid "tool binary restore"

    local sdk="$HOME/.bun/install/global/node_modules/@oh-my-pi/pi-coding-agent/dist/types/index.d.ts"
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
}

run_matrix bash
run_matrix go

MIGRATE_REPO="$T/repo-migrate"
seed_repo "$MIGRATE_REPO"
REPO_ROOT=$PWD
migrate_commit=$(git rev-parse HEAD)
write_gate_receipt test "$migrate_commit" git >/dev/null \
    || fail "migration: v1 receipt write failed"
migrate_receipt=$(gate_receipt_path) || fail "migration: could not resolve receipt path"
jq -e 'has("recipeVersion") | not' "$migrate_receipt" >/dev/null \
    || fail "migration: fixture receipt unexpectedly already carries recipeVersion"

LEG=migrate
SUBSTRATE_ENGINE=go gate_receipt_matches \
    && fail "migration: a v1 receipt was accepted by the go leg"
SUBSTRATE_ENGINE=go write_gate_receipt test "$migrate_commit" git >/dev/null \
    || fail "migration: go regeneration failed"
jq -e '.recipeVersion == 2' "$migrate_receipt" >/dev/null \
    || fail "migration: regenerated receipt is missing recipeVersion:2"
SUBSTRATE_ENGINE=go expect_valid "v1 receipt migrated to recipeVersion 2 on the first go write"

printf 'receipt-test: tree, refs, config, engine, toolchain, SDK, lockfile, revision invalidation green on bash + go legs, v1-migration axis green\n'
