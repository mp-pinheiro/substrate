#!/usr/bin/env bash
# Rollback switch oracle (binding resolution 3): SUBSTRATE_ENGINE=bash wins over
# everything, SUBSTRATE_ENGINE_SKIP keeps named hooks on bash, auto falls back to
# bash when no binary resolves, and an explicit go with no usable binary fails
# closed instead of silently answering from the bash leg.
# The engine is replaced by a tripwire that records its own invocation, so every
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
    "$KIT_ROOT/bin/substrate" init --profile base
    jj git init --colocate .
    jj commit -m 'chore: seed rollback fixture'
) >/dev/null 2>&1 || { printf 'engine-rollback-test: fixture init failed\n' >&2; exit 9; }
[ -f "$REPO/.substrate/engine-shim.sh" ] \
    || { printf 'engine-rollback-test: vendored engine-shim.sh missing — re-vendor first\n' >&2; exit 9; }

HOOKS=(
    "hooks/agent-lifecycle.sh:agent-lifecycle"
    "hooks/protect-paths.sh:protect-paths"
    "hooks/protect-command.sh:protect-command"
    "hooks/enforce-jj.sh:enforce-jj"
    "hooks/enforce-conventional-commits.sh:enforce-conventional-commits"
    "hooks/gate-before-push.sh:gate-before-push"
    "hooks/changed-files-scan.sh:changed-files-scan"
    "comment-ratchet.sh:comment-ratchet"
)

# every hook takes a payload on stdin; only agent-lifecycle needs an action argv
run_hook() {
    local script="$1"
    shift
    local argv=()
    [ "$script" != "hooks/agent-lifecycle.sh" ] || argv=(observe)
    printf '{"session_id":"rollback","tool_input":{"command":"echo hi","file_path":"README.md"}}\n' \
        | ( cd "$REPO" && env "$@" bash ".substrate/$script" "${argv[@]}" ) >/dev/null 2>&1
    printf '%s' "$?"
}

fired() {
    [ -s "$MARKER" ]
}

for entry in "${HOOKS[@]}"; do
    script="${entry%%:*}"
    name="${entry#*:}"

    : > "$MARKER"
    rc=$(run_hook "$script" SUBSTRATE_ENGINE=bash "SUBSTRATE_ENGINE_BIN=$TRIPWIRE")
    if fired; then
        bad "$name: SUBSTRATE_ENGINE=bash still reached the engine"
    elif [ "$rc" = 99 ]; then
        bad "$name: SUBSTRATE_ENGINE=bash returned the engine's exit code"
    else
        ok "$name: SUBSTRATE_ENGINE=bash stays on the bash leg (rc=$rc)"
    fi

    : > "$MARKER"
    rc=$(run_hook "$script" SUBSTRATE_ENGINE=go "SUBSTRATE_ENGINE_BIN=$TRIPWIRE")
    if ! fired; then
        bad "$name: SUBSTRATE_ENGINE=go did not reach the engine — the switch is dead"
    elif [ "$rc" != 99 ]; then
        bad "$name: SUBSTRATE_ENGINE=go did not propagate the engine exit code (rc=$rc)"
    elif ! grep -Eqx "hook $name( observe)?" "$MARKER"; then
        bad "$name: engine received '$(cat "$MARKER")', want 'hook $name'"
    else
        ok "$name: SUBSTRATE_ENGINE=go dispatches 'hook $name' and propagates its exit"
    fi

    : > "$MARKER"
    rc=$(run_hook "$script" SUBSTRATE_ENGINE=go "SUBSTRATE_ENGINE_BIN=$TRIPWIRE" \
        "SUBSTRATE_ENGINE_SKIP=$name")
    if fired; then
        bad "$name: SUBSTRATE_ENGINE_SKIP did not hold the hook on bash"
    else
        ok "$name: SUBSTRATE_ENGINE_SKIP=$name keeps the bash leg (rc=$rc)"
    fi

    : > "$MARKER"
    rc=$(run_hook "$script" SUBSTRATE_ENGINE=auto "SUBSTRATE_ENGINE_BIN=$T/absent-engine")
    if fired; then
        bad "$name: auto ran a nonexistent engine"
    elif [ "$rc" = 2 ] && [ "$name" != protect-paths ] && [ "$name" != protect-command ]; then
        bad "$name: auto failed closed instead of falling back to bash"
    else
        ok "$name: auto with no binary falls back to bash (rc=$rc)"
    fi

    : > "$MARKER"
    rc=$(run_hook "$script" SUBSTRATE_ENGINE=go "SUBSTRATE_ENGINE_BIN=$T/absent-engine")
    if [ "$rc" != 2 ]; then
        bad "$name: explicit go with no binary must fail closed (rc=$rc)"
    else
        ok "$name: explicit go with no binary fails closed"
    fi
done

: > "$MARKER"
rc=$(run_hook hooks/protect-paths.sh SUBSTRATE_ENGINE=nonsense "SUBSTRATE_ENGINE_BIN=$TRIPWIRE")
if fired; then
    bad "unknown SUBSTRATE_ENGINE value reached the engine"
else
    ok "unknown SUBSTRATE_ENGINE value stays on the bash leg (rc=$rc)"
fi

printf 'engine-rollback-test: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
