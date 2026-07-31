#!/usr/bin/env bash
# Executes profile ci install lines so CI never drifts from the profiles —
# new profile, new toolchain, zero workflow edits.
#   default:   every kit profile (profile-matrix job)
#   --active:  only substrate.json active profiles, kit + repo-local (gate job)
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pjsons=()
if [ "${1:-}" = "--active" ]; then
    while IFS= read -r name; do
        for dir in "$KIT_ROOT/profiles/$name" "$KIT_ROOT/substrate-profiles/$name"; do
            if [ -f "$dir/profile.json" ]; then
                pjsons+=("$dir/profile.json")
                break
            fi
        done
    done < <(jq -r '.profiles[]' "$KIT_ROOT/substrate.json")
else
    for pjson in "$KIT_ROOT"/profiles/*/profile.json; do
        pjsons+=("$pjson")
    done
fi

for pjson in "${pjsons[@]}"; do
    name=$(jq -r '.name' "$pjson")
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        printf '[ci-toolchain] %s: %s\n' "$name" "$line"
        bash -c "$line" || { printf '[ci-toolchain] FAILED (%s): %s\n' "$name" "$line" >&2; exit 1; }
    done < <(jq -r '(.ci // [])[]' "$pjson")
done
