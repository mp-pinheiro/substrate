#!/usr/bin/env bash
# Byte oracle for test/golden: rebuild every vector from the same fixture under
# the same pinned toolchain, then cmp. A diff means the bash gate's
# serialization moved, and every downstream engine reading those bytes is wrong.
# Exit 3 (unverifiable) only when the pinned jq cannot be provisioned offline.
# Usage: test/golden-vectors-test.sh
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export LC_ALL=C
GOLDEN_LABEL=golden-vectors-test
# shellcheck source=lib/golden-fixture.sh
source "$KIT_ROOT/test/lib/golden-fixture.sh"

if ! "$KIT_ROOT/test/ci-toolchain.sh" --ensure-jq; then
    printf '\033[0;33m[!]\033[0m %s: pinned %s absent and unfetchable — vectors unverifiable\n' \
        "$GOLDEN_LABEL" "$GOLDEN_JQ_VERSION" >&2
    exit 3
fi
export PATH="$KIT_ROOT/test/.toolchain/bin:$PATH"
golden_assert_toolchain

[ -d "$GOLDEN_DIR" ] \
    || golden_fail "test/golden absent — capture it with: bash test/capture-golden-vectors.sh"

SCRATCH=$(mktemp -d) || golden_fail "scratch dir"
trap 'rm -rf "$SCRATCH"' EXIT

golden_regenerate "$SCRATCH" "$SCRATCH/fresh"
golden_assert_manifest_integrity "$GOLDEN_ROOT"
golden_compare_vectors "$SCRATCH/fresh"

printf 'golden-vectors-test: %d vectors byte-identical under bash %s + %s\n' \
    "${#GOLDEN_VECTORS[@]}" "$BASH_VERSION" "$GOLDEN_JQ_VERSION"
