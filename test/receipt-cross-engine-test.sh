#!/usr/bin/env bash
# Disjoint-generation oracle (B3): a receipt written by one leg is refused by
# the other and self-heals in one regeneration; that refusal is DESIGNED — do not "fix" it.
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/engine-fixture.sh
source "$KIT_ROOT/test/lib/engine-fixture.sh"
engine_fixture_home
engine_fixture_sdk

fail() { printf 'receipt-cross-engine-test FAIL: %s\n' "$1" >&2; exit 1; }
assert_matches() {
    local leg="$1" label="$2"
    SUBSTRATE_ENGINE="$leg" gate_receipt_matches || fail "$leg: $label did not match"
}
assert_refuses() {
    local leg="$1" label="$2"
    SUBSTRATE_ENGINE="$leg" gate_receipt_matches && fail "$leg: $label was accepted, expected refusal"
    return 0
}

command -v go >/dev/null 2>&1 || fail "go is required for the go-leg replay"
SUBSTRATE_ENGINE_BIN=$(engine_build fail go "$(cat VERSION)") || exit 1
export SUBSTRATE_ENGINE_BIN

source "$KIT_ROOT/core/receipt-lib.sh"

# shellcheck source=lib/receipt-fixture.sh
source "$KIT_ROOT/test/lib/receipt-fixture.sh"

cross_engine_case() {
    local writer="$1" reader="$2" commit repo
    repo="$T/repo-$writer"
    seed_repo "$repo"
    REPO_ROOT=$PWD
    commit=$(git rev-parse HEAD)
    SUBSTRATE_ENGINE="$writer" write_gate_receipt test "$commit" git >/dev/null \
        || fail "$writer: initial receipt write failed"

    assert_matches "$writer" "the $writer-written receipt read on its own leg"
    assert_refuses "$reader" "the $writer-written receipt read on the $reader leg"

    SUBSTRATE_ENGINE="$reader" write_gate_receipt test "$commit" git >/dev/null \
        || fail "$reader: single regeneration over a $writer-written receipt failed"
    assert_matches "$reader" "the $reader-regenerated receipt after exactly one write"
}

cross_engine_case bash go
cross_engine_case go bash

printf 'receipt-cross-engine-test: bash/go receipt generations stay disjoint and self-heal in one write, both directions\n'
