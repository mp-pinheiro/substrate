#!/usr/bin/env bash
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$TEST_DIR/lib"
source "$LIB_DIR/engine-fixture.sh"

export LC_ALL=C
export SUBSTRATE_NO_USER_HARNESS=1

PASS=0; FAIL=0
ok()  { printf '  [ok] %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  [XX] %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

T=$(mktemp -d) || exit 9
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"
mkdir -p "$HOME" || exit 9
_engine_fixture_sdk_root "$T"
export XDG_CONFIG_HOME="$T/xdg-config"
mkdir -p "$XDG_CONFIG_HOME"

real_bin=$(engine_build bad "maintenance-rollback") || exit 2

mk_git_maintenance_fixture() {
    local d="$1"
    mkdir -p "$d" && cd "$d" || return 1
    git init -q --initial-branch=main
    git config user.name substrate
    git config user.email substrate@localhost
    printf '#!/usr/bin/env bash\nprintf "ok\\n"\n' > app.sh
    chmod +x app.sh
    git add app.sh && git commit -qm 'chore: seed app'
    "$KIT_ROOT/bin/substrate" init --from-worktree --profile shell --vcs git > "$T/init.out" 2> "$T/init.err" \
        || { printf 'fixture init failed\n' >&2; cat "$T/init.err" >&2; return 1; }
    printf '{"probe:alpha":10}\n' > .git/probe-metrics.json
    git add -A && git commit -qm 'chore: initialize'
    substrate-engine gate --update-baseline >/dev/null 2>&1 || return 1
    git add substrate-baseline.json && git commit -qm 'chore: establish baseline'
    mkdir -p checks.d
    printf '#!/usr/bin/env bash\nexit 0\n' > checks.d/85-local.sh
    chmod +x checks.d/85-local.sh
    git add checks.d/85-local.sh
    git commit -q --no-verify -m 'chore: add local check'
    test -x .substrate/maintenance.sh || { printf 'fixture: maintenance.sh missing after init\n' >&2; return 1; }
}

printf 'maintenance-rollback: go-only maintenance transaction\n'

d="$T/maint-go"; mk_git_maintenance_fixture "$d"
cd "$d" || exit 1
SUBSTRATE_ENGINE_BIN="$real_bin" SUBSTRATE_KIT_ROOT="$KIT_ROOT" \
    "$KIT_ROOT/bin/substrate" bootstrap --from-worktree --checkpoint --repo-only > "$T/maint.out" 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then
    ok "maintenance: engine succeeds (rc=$rc)"
else
    cat "$T/maint.out" >&2
    bad "maintenance: engine failed (rc=$rc)"
fi

if [ "$FAIL" -gt 0 ]; then
    printf '\nmaintenance-rollback: %d passed, %d failed\n' "$PASS" "$FAIL"
    exit 1
fi
printf '\nmaintenance-rollback: %d passed\n' "$PASS"
exit 0
