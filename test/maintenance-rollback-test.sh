#!/usr/bin/env bash
# Maintenance rollback switch oracle (A.S2).
# Tests SUBSTRATE_ENGINE=bash|go|auto delegation for the maintenance verb.
# Clones transaction-rollback-test.sh structurally, adapted for maintenance.
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$TEST_DIR/lib"
source "$LIB_DIR/engine-fixture.sh"

export LC_ALL=C
export SUBSTRATE_NO_USER_HARNESS=1

PASS=0; FAIL=0; SKIP=0
ok()  { printf '  [ok] %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  [XX] %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
skip() { printf '  [--] %s (delegation probe not yet active)\n' "$1"; SKIP=$((SKIP + 1)); }

T=$(mktemp -d) || exit 9
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"
mkdir -p "$HOME" || exit 9
_engine_fixture_sdk_root "$T"
export XDG_CONFIG_HOME="$T/xdg-config"
mkdir -p "$XDG_CONFIG_HOME"

TRIPWIRE="$T/bin/substrate-engine"
MARKER="$T/tripwire.log"
mkdir -p "$T/bin" || exit 9
cat > "$TRIPWIRE" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
    capabilities) printf 'maintenance\n'; exit 0 ;;
    maintenance)  printf '%s\n' "\$*" >> "$MARKER"; exit 99 ;;
    *)            exit 0 ;;
esac
SH
chmod +x "$TRIPWIRE" || exit 9

real_bin=$(engine_build bad "maintenance-rollback") || exit 2
fired() { [ -s "$MARKER" ]; }
has_probe() { grep -q 'substrate_engine_supports' "$KIT_ROOT/.substrate/$1" 2>/dev/null; }

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
    .substrate/gate.sh --update-baseline >/dev/null 2>&1 || return 1
    git add substrate-baseline.json && git commit -qm 'chore: establish baseline'
    mkdir -p checks.d
    printf '#!/usr/bin/env bash\nexit 0\n' > checks.d/85-local.sh
    chmod +x checks.d/85-local.sh
    git add checks.d/85-local.sh
    git commit -q --no-verify -m 'chore: add local check'
    test -x .substrate/maintenance.sh || { printf 'fixture: maintenance.sh missing after init\n' >&2; return 1; }
}

# run_maint_no_path: no tripwire on PATH; delegation uses SUBSTRATE_ENGINE_BIN only. gate:allow-comment
run_maint_no_path() {
    local dir="$1" mode="$2" bin="$3"
    shift 3
    SUBSTRATE_ENGINE="$mode" SUBSTRATE_ENGINE_BIN="$bin" \
        SUBSTRATE_KIT_ROOT="$KIT_ROOT" \
        "$KIT_ROOT/bin/substrate" bootstrap --from-worktree --checkpoint --repo-only "$@"
}

# run_maint: tripwire on PATH for go delegation, scoped to subshell to prevent leak.
run_maint() {
    local dir="$1" mode="$2" bin="$3"
    shift 3
    cd "$dir" || return 1
    (
        export PATH="$T/bin:$PATH"
        SUBSTRATE_ENGINE="$mode" SUBSTRATE_ENGINE_BIN="$bin" \
            SUBSTRATE_KIT_ROOT="$KIT_ROOT" \
            "$KIT_ROOT/bin/substrate" bootstrap --from-worktree --checkpoint --repo-only "$@"
    )
}

# run_maint_real: real engine's dir on PATH, scoped to subshell.
run_maint_real() {
    local dir="$1" mode="$2" bin="$3"
    shift 3
    cd "$dir" || return 1
    (
        _path="$(dirname "$bin"):$PATH"; export PATH="$_path"
        SUBSTRATE_ENGINE="$mode" SUBSTRATE_ENGINE_BIN="$bin" \
            SUBSTRATE_KIT_ROOT="$KIT_ROOT" \
            "$KIT_ROOT/bin/substrate" bootstrap --from-worktree --checkpoint --repo-only "$@"
    )
}

printf 'maintenance-rollback: SUBSTRATE_ENGINE delegation switch\n'

# (a) bash — marker must NOT fire; rc 0. No SUBSTRATE_ENGINE_BIN set so hooks don't delegate.
d="$T/maint-bash"; mk_git_maintenance_fixture "$d"
run_maint_no_path "$d" bash ""; rc=$?
fired && bad "maintenance: bash reached engine" \
    || { [ "$rc" -eq 0 ] && ok "maintenance: bash leg (rc=$rc)" || bad "maintenance: bash failed (rc=$rc)"; }
# (b) go delegates — tripwire on PATH, marker MUST fire; rc 99
if has_probe "maintenance.sh"; then
    true > "$MARKER"
    d="$T/maint-go"; mk_git_maintenance_fixture "$d"
    run_maint "$d" go "$TRIPWIRE"; rc=$?
    unset d
    fired && [ "$rc" -eq 99 ] && ok "maintenance: go delegates (rc=99,tripwire)" \
        || { [ "$rc" -eq 99 ] && bad "maintenance: go delegate rc ok but marker absent" || bad "maintenance: go delegate unexpected (rc=$rc)"; }
else
    skip "maintenance: SUBSTRATE_ENGINE=go"
fi

# (c) go no-binary fails closed — rc≠0 gate:allow-comment
# The tripwire on PATH shadows the "no binary" check (same as transaction-rollback).
if has_probe "maintenance.sh"; then
    d="$T/maint-nobin"; mk_git_maintenance_fixture "$d"
    run_maint "$d" go "/nonexistent/substrate-engine"; rc=$?
    unset d
    [ "$rc" -ne 0 ] && ok "maintenance: go no-binary fails closed (rc=$rc)" \
        || bad "maintenance: go no-binary unexpectedly succeeded (rc=$rc)"
else
    skip "maintenance: SUBSTRATE_ENGINE=go no binary"
fi

# (d) auto fallback: no tripwire on PATH; marker NOT fired; rc 0. gate:allow-comment
if has_probe "maintenance.sh"; then
    true > "$MARKER"
    d="$T/maint-auto-fb"; mk_git_maintenance_fixture "$d"
    run_maint_no_path "$d" auto "/nonexistent/substrate-engine"; rc=$?
    fired && bad "maintenance: auto wrongfully reached engine" \
        || { [ "$rc" -eq 0 ] && ok "maintenance: auto fallback (rc=$rc)" || bad "maintenance: auto fallback failed (rc=$rc)"; }
else
    skip "maintenance: SUBSTRATE_ENGINE=auto"
fi

# (e) auto delegates: real engine on PATH; marker must NOT fire; any rc acceptable. gate:allow-comment
if has_probe "maintenance.sh"; then
    true > "$MARKER"
    d="$T/maint-auto-real"; mk_git_maintenance_fixture "$d"
    run_maint_real "$d" auto "$real_bin"; rc=$?
    unset d
    fired && bad "maintenance: auto reached tripwire instead of real engine" \
        || ok "maintenance: auto delegates (rc=$rc, real engine)"
else
    skip "maintenance: SUBSTRATE_ENGINE=auto (real)"
fi
if [ "$FAIL" -gt 0 ]; then
    printf '\nmaintenance-rollback: %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
    exit 1
fi
printf '\nmaintenance-rollback: %d passed, %d skipped\n' "$PASS" "$SKIP"
exit 0
