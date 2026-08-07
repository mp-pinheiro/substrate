#!/usr/bin/env bash
# Byte oracle for test/golden/ledger: bash leg reproduces the committed
# vectors, then a self-built go leg (amendments A1/A25) replays the same
# fixture against them, proving A8 non-ASCII/invalid-UTF-8 handling
# bug-for-bug. Exit 3 (unverifiable) only when the pinned jq is unfetchable.
# Usage: test/golden-ledger-test.sh
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export LC_ALL=C
export LEDGER_LABEL=golden-ledger-test
# shellcheck source=lib/ledger-fixture.sh
source "$KIT_ROOT/test/lib/ledger-fixture.sh"
# shellcheck source=lib/engine-fixture.sh
source "$KIT_ROOT/test/lib/engine-fixture.sh"

if ! "$KIT_ROOT/test/ci-toolchain.sh" --ensure-jq; then
    printf '\033[0;33m[!]\033[0m %s: pinned %s absent and unfetchable — vectors unverifiable\n' \
        "$LEDGER_LABEL" "$LEDGER_JQ_VERSION" >&2
    exit 3
fi
export PATH="$KIT_ROOT/test/.toolchain/bin:$PATH"
command -v go >/dev/null 2>&1 || ledger_fail "go is required for the go-leg replay"
ledger_assert_toolchain

[ -d "$LEDGER_DIR" ] \
    || ledger_fail "test/golden/ledger absent — capture it with: bash test/capture-golden-ledger.sh"

SCRATCH=$(mktemp -d) || ledger_fail "scratch dir"
trap 'rm -rf "$SCRATCH"' EXIT

ledger_regenerate "$SCRATCH" "$SCRATCH/fresh-bash" bash || ledger_fail "bash regeneration failed"
ledger_compare_vectors "$SCRATCH/fresh-bash"

printf 'golden-ledger-test: %d vectors byte-identical under bash %s + %s\n' \
    "${#LEDGER_VECTORS[@]}" "$BASH_VERSION" "$LEDGER_JQ_VERSION"

SUBSTRATE_ENGINE_BIN=$(engine_build ledger_fail go) || exit 1
export SUBSTRATE_ENGINE_BIN

ledger_regenerate "$SCRATCH" "$SCRATCH/fresh-go" go || ledger_fail "go regeneration failed"
ledger_compare_vectors "$SCRATCH/fresh-go"
printf 'golden-ledger-test: go leg reproduces the same %d vectors\n' "${#LEDGER_VECTORS[@]}"
