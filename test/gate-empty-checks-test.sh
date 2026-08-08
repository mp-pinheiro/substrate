#!/usr/bin/env bash
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/scratch-repo-fixture.sh
source "$KIT_ROOT/test/lib/scratch-repo-fixture.sh"

fail() { printf 'gate-empty-checks-test FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { printf '\033[0;32m[ok]\033[0m gate-empty-checks-test: %s\n' "$*"; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export HOME="$T/home" SUBSTRATE_NO_USER_HARNESS=1
mkdir -p "$HOME"
scratch_repo_init "$T/repo" base || fail "init failed"
cd "$T/repo" || exit 9
printf 'safe\n' > tracked.txt
git add -A
git commit -qm 'seed'

rm -f .substrate/checks.d/*.sh
out=$(.substrate/gate.sh 2>&1)
rc=$?

if [ "$rc" -ne 3 ]; then
    fail "empty checks.d expected exit 3, got $rc. Output: $out"
fi
printf '%s\n' "$out" | grep -q 'no checks in' \
    || fail "missing 'no checks in' guard message: $out"
ok "empty checks.d exits 3 with guard message"
