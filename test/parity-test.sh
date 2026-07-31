#!/usr/bin/env bash
# Firing oracle for 81-harness-parity: strip one mirror marker and the check
# must go red naming the orphaned hook; the real tree must pass.
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$KIT_ROOT" || exit 9

fail() { printf 'parity-test FAIL: %s\n' "$1" >&2; exit 1; }

checks.d/81-harness-parity.sh >/dev/null || fail "real tree does not pass parity"

T=$(mktemp)
trap 'rm -f "$T"' EXIT
grep -v 'mirrors: gate-before-push.sh' core/omp/substrate-quality.ts > "$T"
out=$(checks.d/81-harness-parity.sh "$T")
rc=$?
[ "$rc" -ne 0 ] || fail "check stayed green with a stripped mirror"
printf '%s' "$out" | grep -q 'gate-before-push.sh' || fail "red run does not name the orphaned hook"

printf 'parity-test: fires on stripped mirror, green on real tree\n'
