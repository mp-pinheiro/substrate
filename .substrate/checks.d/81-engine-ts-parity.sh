#!/usr/bin/env bash
# Parity gate for the omp harness's Go delegation: every dispatched hook has a
# claude-hooks.json entry and a dispatch.go case, and the write/bash-command
# guards call substrate-engine rather than reimplementing policy in TypeScript.
set -uo pipefail

HOOKS_JSON="core/claude-hooks.json"
DISPATCH_GO="internal/hook/dispatch.go"
OMP_TS="core/omp/substrate-quality.ts"

[ -f "$HOOKS_JSON" ] || exit 0

infra() { printf 'infra: %s\n' "$*" >&2; exit 3; }
[ -f "$DISPATCH_GO" ] || infra "$HOOKS_JSON present but $DISPATCH_GO missing"

rc=0

declare -A hooks=()
while IFS= read -r cmd; do
    read -r _ _ name _ <<<"$cmd"
    [ -n "$name" ] && hooks["$name"]=1
done < <(jq -r '.hooks[][]?.hooks[].command // empty' "$HOOKS_JSON" \
            | grep -E '^substrate-engine hook ')

# Internal-only engine hooks are called by the OMP adapter for narrower
# classifications and must not be exposed as Claude hook targets.
declare -A internal_only=([check-hard]=1)

if [ "${#hooks[@]}" -eq 0 ]; then
    printf 'no "substrate-engine hook" identities found in %s\n' "$HOOKS_JSON"
    rc=1
fi

for name in "${!hooks[@]}"; do
    if ! grep -qE "^[[:space:]]*case \"$name\":" "$DISPATCH_GO"; then
        printf 'hook "%s" registered in claude-hooks.json has no case in %s\n' \
            "$name" "$DISPATCH_GO"
        rc=1
    fi
done

[ -f "$OMP_TS" ] || infra "$HOOKS_JSON present but $OMP_TS missing"
if grep -q '\.substrate/hooks/changed-files-scan' "$OMP_TS"; then
    printf '%s still references the deleted .substrate/hooks/changed-files-scan path\n' "$OMP_TS"
    rc=1
fi
if ! grep 'changed-files-scan' "$OMP_TS" | grep -qE 'substrate-engine|engineBaseCmd'; then
    printf '%s does not invoke changed-files-scan via substrate-engine\n' "$OMP_TS"
    rc=1
fi

OMP_POLICY="core/omp/substrate-quality/policy.ts"
if [ -f "$OMP_POLICY" ] && grep -qE 'const HARD|function globToRegExp|function loadConfig' "$OMP_POLICY"; then
    printf '%s reimplements the protected-path policy in TypeScript (issue #12 consolidation)\n' "$OMP_POLICY"
    rc=1
fi
if ! grep 'protect-paths' "$OMP_TS" | grep -qE 'substrate-engine|engineBaseCmd'; then
    printf '%s does not invoke protect-paths via substrate-engine\n' "$OMP_TS"
    rc=1
fi

OMP_RUNTIME="core/omp/substrate-quality/runtime.ts"
# The omp extension delegates ownership tracking to the engine (issue #12 rc #3):
# feed the ledger via observe; never reimplement fingerprints or deleted hooks.
if ! grep -qE 'engineObserve|agent-lifecycle.*observe' "$OMP_TS" "$OMP_RUNTIME" 2>/dev/null; then
    printf 'omp extension does not feed the engine ownership ledger — engineObserve missing\n'
    rc=1
fi
if [ -f "$OMP_RUNTIME" ] && grep -qE 'function workingSnapshot|fingerprint.*createHash' "$OMP_RUNTIME"; then
    printf 'omp runtime reimplements the ownership fingerprint tracker in-process (issue #12 rc #3)\n'
    rc=1
fi
if grep -q '\.substrate/hooks/protect-command' "$OMP_TS"; then
    printf '%s still references the deleted .substrate/hooks/protect-command path\n' "$OMP_TS"
    rc=1
fi

while IFS= read -r dcase; do
    v="${dcase#case \"}"
    v="${v%\"}"
    if [ "$v" != "comment-ratchet" ] && [ -z "${hooks[$v]+x}" ] && [ -z "${internal_only[$v]+x}" ]; then
        printf 'note: dispatch verb "%s" has no claude-hooks.json entry\n' "$v" >&2
    fi
done < <(grep -oE 'case "[A-Za-z0-9._-]+"' "$DISPATCH_GO")

exit "$rc"
