#!/usr/bin/env bash
# Executes profile ci install lines so CI never drifts from the profiles —
# new profile, new toolchain, zero workflow edits.
#   default:   every kit profile (profile-matrix job)
#   --active:  only substrate.json active profiles, kit + repo-local (gate job)
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

add_profile() {
    for dir in "$KIT_ROOT/profiles/$1" "$KIT_ROOT/substrate-profiles/$1"; do
        [ -f "$dir/profile.json" ] && { pjsons+=("$dir/profile.json"); return; }
    done
}

pjsons=()
case "${1:-}" in
    --active)
        while IFS= read -r name; do add_profile "$name"; done \
            < <(jq -r '.profiles[]' "$KIT_ROOT/substrate.json") ;;
    "")
        for pjson in "$KIT_ROOT"/profiles/*/profile.json; do pjsons+=("$pjson"); done ;;
    *)
        for name in base "$@"; do add_profile "$name"; done ;;
esac

for pjson in "${pjsons[@]}"; do
    name=$(jq -r '.name' "$pjson")
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        printf '[ci-toolchain] %s: %s\n' "$name" "$line"
        bash -c "$line" || { printf '[ci-toolchain] FAILED (%s): %s\n' "$name" "$line" >&2; exit 1; }
    done < <(jq -r '(.ci // [])[]' "$pjson")
done
