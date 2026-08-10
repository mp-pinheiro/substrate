#!/usr/bin/env bash
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
if ! grep 'changed-files-scan' "$OMP_TS" | grep -q 'substrate-engine'; then
    printf '%s does not invoke changed-files-scan via substrate-engine\n' "$OMP_TS"
    rc=1
fi

while IFS= read -r dcase; do
    v="${dcase#case \"}"
    v="${v%\"}"
    [ -n "${hooks[$v]+x}" ] || printf 'note: dispatch verb "%s" has no claude-hooks.json entry (comment-ratchet is folded into changed-files-scan)\n' "$v" >&2
done < <(grep -oE 'case "[A-Za-z0-9._-]+"' "$DISPATCH_GO")

exit "$rc"
