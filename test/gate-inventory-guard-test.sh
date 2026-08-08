#!/usr/bin/env bash
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/scratch-repo-fixture.sh
source "$KIT_ROOT/test/lib/scratch-repo-fixture.sh"

fail() { printf 'gate-inventory-guard-test FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { printf '\033[0;32m[ok]\033[0m gate-inventory-guard-test: %s\n' "$*"; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export HOME="$T/home" SUBSTRATE_NO_USER_HARNESS=1
mkdir -p "$HOME"

scratch_repo_init "$T/repo" shell || fail "init failed"

cd "$T/repo" || exit 9
printf '#!/usr/bin/env bash\necho ok\n' > ok.sh
chmod +x ok.sh

export SUBSTRATE_FILE_LIST=/dev/null
out=$(.substrate/gate.sh 2>&1)
rc=$?
if [ "$rc" -ne 3 ]; then
    fail "expected exit 3 for empty scoped inventory, got $rc"
fi
printf '%s\n' "$out" | grep -q 'SUBSTRATE_FILE_LIST is empty' \
    || fail "missing 'SUBSTRATE_FILE_LIST is empty' in output: $out"
ok "empty scoped inventory exits 3 with guard message"
