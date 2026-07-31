#!/usr/bin/env bash
# Every tracked file is either claimed by a profile or listed in the reviewed
# `unscanned` ledger. Silence is a decision, never a default.
set -uo pipefail
# shellcheck source=../gate-lib.sh
source "$SUBSTRATE_DIR/gate-lib.sh"

mapfile -t UNSCANNED < <(cfg_json '.unscanned // []' | jq -r '.[]')

rc=0
while IFS= read -r f; do
    claimed "$f" && continue
    skip=0
    for g in ${UNSCANNED[@]+"${UNSCANNED[@]}"}; do
        # shellcheck disable=SC2254 # globs are the contract here
        case "$f" in
            $g) skip=1; break ;;
        esac
    done
    [ "$skip" -eq 1 ] && continue
    printf '%s: claimed by no profile — add a profile claim or list it in substrate.json unscanned\n' "$f"
    rc=1
done < "$INVENTORY"

exit "$rc"
