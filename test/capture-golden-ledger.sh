#!/usr/bin/env bash
# Captures the byte-frozen session-ledger vectors (amendment A8: non-ASCII and
# invalid-UTF-8 paths) from the current bash lifecycle hook under the pinned
# toolchain. A vector diff is a semantic decision, never a refresh: recapture
# only with the change that moved the bytes, and commit both in the same change.
# Usage: test/capture-golden-ledger.sh
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export LC_ALL=C
export LEDGER_LABEL=capture-golden-ledger
# shellcheck source=lib/ledger-fixture.sh
source "$KIT_ROOT/test/lib/ledger-fixture.sh"

"$KIT_ROOT/test/ci-toolchain.sh" --ensure-jq \
    || ledger_fail "pinned jq unavailable — capture refuses to run against ambient jq"
export PATH="$KIT_ROOT/test/.toolchain/bin:$PATH"
ledger_assert_toolchain

SCRATCH=$(mktemp -d) || ledger_fail "scratch dir"
trap 'rm -rf "$SCRATCH"' EXIT

mkdir -p "$LEDGER_DIR" || ledger_fail "cannot create test/golden/ledger"
ledger_regenerate "$SCRATCH" "$LEDGER_DIR" bash || ledger_fail "regeneration failed"
ledger_write_manifest "$LEDGER_DIR" || ledger_fail "manifest write failed"

for vector in "${LEDGER_VECTORS[@]}" "$LEDGER_MANIFEST"; do
    hash=$(ledger_file_sha256 "$LEDGER_DIR/$vector") || ledger_fail "cannot hash test/golden/ledger/$vector"
    ledger_ok "test/golden/ledger/$vector sha256 ${hash:0:12}"
done
ledger_ok "captured under bash $BASH_VERSION + $LEDGER_JQ_VERSION"
