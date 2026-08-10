#!/usr/bin/env bash
# Post-P5a: 80-vendor-drift.sh is deleted — the vendored engine bodies are
# gone, so drift between core/ and .substrate/ is structurally impossible for
# the deleted set. Verify the P5 layout: retained files present, deleted files
# absent.
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$KIT_ROOT" || exit 9

fail() { printf 'vendor-drift-test FAIL: %s\n' "$1" >&2; exit 1; }

for f in gate-lib.sh check-comments.sh engine-shim.sh VERSION; do
    [ -f ".substrate/$f" ] || fail "retained file .substrate/$f is missing"
done

for f in gate.sh checkpoint.sh restructure.sh comment-ratchet.sh \
         maintenance-lib.sh maintenance-cli.sh maintenance-receipt.sh \
         maintenance-sync.sh maintenance-transaction.sh; do
    [ ! -e ".substrate/$f" ] || fail "deleted file .substrate/$f still vendored"
done
[ ! -e ".substrate/hooks" ] || fail ".substrate/hooks still vendored"

printf 'vendor-drift-test: P5 layout verified (retained present, deleted absent)\n'
