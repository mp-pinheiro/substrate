#!/usr/bin/env bash
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/scratch-repo-fixture.sh
source "$KIT_ROOT/test/lib/scratch-repo-fixture.sh"

fail() { printf 'comment-colon-test FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { printf '\033[0;32m[ok]\033[0m comment-colon-test: %s\n' "$*"; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export HOME="$T/home" SUBSTRATE_NO_USER_HARNESS=1
mkdir -p "$HOME"

scratch_repo_init "$T/repo" shell || fail "init failed"

cd "$T/repo" || exit 9
mkdir -p src
cat > src/foo.sh <<'SH'
#!/usr/bin/env bash
echo "hello"
# fetch the articles
echo "hello"
SH
chmod +x src/foo.sh
git add src/foo.sh
git commit -qm 'feat: fixture'

export SUBSTRATE_FILE_LIST="$T/repo/.filelist"
printf 'src/foo.sh\n' > "$SUBSTRATE_FILE_LIST"

if ! substrate-engine gate --update-baseline > "$T/out" 2>&1; then
    cat "$T/out" >&2
    fail "gate --update-baseline failed"
fi

jq -e '.metrics["comments:src/foo.sh"]' substrate-baseline.json >/dev/null \
    || fail "comments:src/foo.sh not in baseline"
ok "comment metrics emitted with correct path"
