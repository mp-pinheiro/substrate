#!/usr/bin/env bash
# Post-P5a engine dispatch oracle: with no in-tree bash hook leg, every hook
# dispatch always reaches the engine. The engine is replaced by a tripwire that
# records its own invocation, so every scenario must confirm the tripwire fired.
# assertion is two-sided: the bash leg must NOT fire it, the go leg MUST.
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export LC_ALL=C
export SUBSTRATE_NO_USER_HARNESS=1

PASS=0
FAIL=0
ok()  { printf '  [ok] %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  [XX] %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

T=$(mktemp -d) || exit 9
T=$(cd "$T" && pwd -P) || exit 9
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"
mkdir -p "$HOME" || exit 9
export JJ_USER=substrate JJ_EMAIL=substrate@localhost

TRIPWIRE="$T/bin/substrate-engine"
MARKER="$T/tripwire.log"
mkdir -p "$T/bin" || exit 9
cat > "$TRIPWIRE" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$MARKER'
exit 99
SH
chmod +x "$TRIPWIRE" || exit 9

REPO="$T/repo"
mkdir -p "$REPO" || exit 9
(
    cd "$REPO" || exit 9
    git init -q --initial-branch=main
    printf 'seed\n' > README.md
    "$KIT_ROOT/bin/substrate" init --profile base --from-worktree
    jj git init --colocate .
    jj commit -m 'chore: seed rollback fixture'
) >/dev/null 2>&1 || { printf 'engine-rollback-test: fixture init failed\n' >&2; exit 9; }
[ -f "$REPO/.substrate/engine-shim.sh" ] \
    || { printf 'engine-rollback-test: vendored engine-shim.sh missing — re-vendor first\n' >&2; exit 9; }

HOOKS=(
    "agent-lifecycle"
    "protect-paths"
    "protect-command"
    "enforce-jj"
    "enforce-conventional-commits"
    "gate-before-push"
    "changed-files-scan"
    "comment-ratchet"
)

# every hook takes a payload on stdin; only agent-lifecycle needs an action argv
# post-P5a: hooks dispatch is always through the engine; SUBSTRATE_ENGINE env is moot
run_hook() {
    local name="$1"
    shift
    local argv=()
    [ "$name" != "agent-lifecycle" ] || argv=(observe)
    printf '{"session_id":"rollback","tool_input":{"command":"echo hi","file_path":"README.md"}}\n' \
        | ( cd "$REPO" && env "$@" "$TRIPWIRE" hook "$name" "${argv[@]}" ) >/dev/null 2>&1
    printf '%s' "$?"
}

fired() {
    [ -s "$MARKER" ]
}

for name in "${HOOKS[@]}"; do
    : > "$MARKER"
    rc=$(run_hook "$name" SUBSTRATE_ENGINE_BIN="$TRIPWIRE")
    if ! fired; then
        bad "$name: engine not reached — the dispatch path is dead"
    elif [ "$rc" != 99 ]; then
        bad "$name: engine exit code not propagated (rc=$rc)"
    elif ! grep -Eqx "hook $name( observe)?" "$MARKER"; then
        bad "$name: engine received '$(cat "$MARKER")', want 'hook $name'"
    else
        ok "$name: engine dispatches 'hook $name' and propagates its exit"
    fi

    : > "$MARKER"
    rc=$( ( cd "$REPO" && "$T/absent-engine" hook "$name" ) >/dev/null 2>&1; printf '%s' "$?" )
    if [ "$rc" != 127 ]; then
        bad "$name: absent engine must fail (rc=$rc, want 127)"
    else
        ok "$name: absent engine fails closed"
    fi
done

: > "$MARKER"
rc=$(run_hook "protect-paths" SUBSTRATE_ENGINE_BIN="$TRIPWIRE")
if fired; then
    ok "any SUBSTRATE_ENGINE value reaches the engine (tripwire fired)"
else
    bad "any SUBSTRATE_ENGINE value did not reach the engine"
fi
printf 'engine-rollback-test: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

