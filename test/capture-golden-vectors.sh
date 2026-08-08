#!/usr/bin/env bash
# Captures the byte-frozen gate artifacts (baseline, metrics jsonl, CLAIMS
# table) from the deterministic golden fixture under the pinned toolchain.
# A vector diff is a semantic decision, never a refresh: recapture only with
# the change that moved the bytes, and commit both in the same change.
# Usage: test/capture-golden-vectors.sh
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export LC_ALL=C
export GOLDEN_LABEL=capture-golden-vectors
# shellcheck source=lib/golden-fixture.sh
source "$KIT_ROOT/test/lib/golden-fixture.sh"

"$KIT_ROOT/test/ci-toolchain.sh" --ensure-jq \
    || golden_fail "pinned jq unavailable — capture refuses to run against ambient jq"
export PATH="$KIT_ROOT/test/.toolchain/bin:$PATH"
golden_assert_toolchain

export GOLDEN_ENGINE=bash
export SUBSTRATE_VENDOR_FROM_WORKTREE=1

SCRATCH=$(mktemp -d) || golden_fail "scratch dir"
trap 'rm -rf "$SCRATCH"' EXIT

mkdir -p "$GOLDEN_DIR" || golden_fail "cannot create test/golden"
golden_regenerate "$SCRATCH" "$GOLDEN_DIR"
golden_write_manifest "$GOLDEN_ROOT" "$GOLDEN_DIR"

for vector in "${GOLDEN_VECTORS[@]}" "$GOLDEN_MANIFEST"; do
    hash=$(golden_file_sha256 "$GOLDEN_DIR/$vector") || golden_fail "cannot hash test/golden/$vector"
    golden_ok "test/golden/$vector sha256 ${hash:0:12}"
done
golden_ok "captured under bash $BASH_VERSION + $GOLDEN_JQ_VERSION"
