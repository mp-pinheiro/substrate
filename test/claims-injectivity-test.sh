#!/usr/bin/env bash
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/scratch-repo-fixture.sh
source "$KIT_ROOT/test/lib/scratch-repo-fixture.sh"

fail() { printf 'claims-injectivity-test FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { printf '\033[0;32m[ok]\033[0m claims-injectivity-test: %s\n' "$*"; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export HOME="$T/home" SUBSTRATE_NO_USER_HARNESS=1
mkdir -p "$HOME"

scratch_repo_init "$T/repo" shell || fail "init failed"

cd "$T/repo" || exit 9
printf '#!/usr/bin/env bash\necho ok\n' > ok.sh
printf '#!/usr/bin/env bash\necho 0x1f\n' > $'bad\x1fname.sh'
chmod +x ok.sh $'bad\x1fname.sh'

export SUBSTRATE_FILE_LIST="$T/repo/.filelist"
printf 'ok.sh\nbad\x1fname.sh\n' > "$SUBSTRATE_FILE_LIST"

out=$(.substrate/gate.sh 2>&1)
rc=$?
if [ "$rc" -ne 3 ]; then
    fail "expected exit 3 for 0x1F path, got $rc. Output: $out"
fi
printf '%s\n' "$out" | grep -q '0x1F byte in path' \
    || fail "missing '0x1F byte in path' in output: $out"
ok "0x1F path triggers die_infra exit 3"
