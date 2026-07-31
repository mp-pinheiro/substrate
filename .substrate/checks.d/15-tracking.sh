#!/usr/bin/env bash
# Structural gate on plan tracking (".pi/plans"): plans are the durable home
# for research, decisions, and acceptance — attrition is a gate failure, not
# an accident. Fast checks only; `substrate audit` executes the oracles in CI.
set -uo pipefail
# shellcheck source=../gate-lib.sh
source "$SUBSTRATE_DIR/gate-lib.sh"

PLANS="$REPO_ROOT/.pi/plans"
[ -d "$PLANS" ] || exit 0

rc=0
found=0
for plan in "$PLANS"/*.md; do
    [ -f "$plan" ] || continue
    found=1
    rel="${plan#"$REPO_ROOT"/}"
    states=$(grep -c '^state: ' "$plan")
    state=$(grep -m1 '^state: ' "$plan" | cut -d' ' -f2)
    if [ "$states" -ne 1 ] || ! printf '%s' "$state" | grep -qxE 'draft|active|committed|superseded|abandoned'; then
        printf '%s — needs exactly one "state: draft|active|committed|superseded|abandoned" line\n' "$rel"
        rc=1
        continue
    fi
    items=0 unchecked=0 malformed=0 in_acceptance=0
    while IFS= read -r line; do
        case "$line" in
            '## Acceptance'*) in_acceptance=1; continue ;;
            '## '*) in_acceptance=0; continue ;;
        esac
        [ "$in_acceptance" -eq 1 ] || continue
        case "$line" in
            '- ['*)
                if printf '%s' "$line" | grep -qE '^- \[[ x]\] .+ :: .+$'; then
                    items=$((items + 1))
                    case "$line" in '- [ ]'*) unchecked=$((unchecked + 1)) ;; esac
                else
                    printf '%s — malformed acceptance item (want "- [ ] claim :: verify-cmd"): %s\n' "$rel" "$line"
                    malformed=$((malformed + 1))
                fi
                ;;
        esac
    done < "$plan"
    [ "$malformed" -eq 0 ] || rc=1
    if [ "$state" = "active" ] && [ "$items" -eq 0 ]; then
        printf '%s — active plan with no acceptance oracles (add "## Acceptance" items or change state)\n' "$rel"
        rc=1
    fi
    if [ "$state" = "committed" ] && [ "$unchecked" -gt 0 ]; then
        printf '%s — committed plan with %d unchecked item(s): a committed plan claims done\n' "$rel" "$unchecked"
        rc=1
    fi
    if [ "$state" = "committed" ] && [ "$items" -eq 0 ] && ! grep -q '^acceptance: none — .' "$plan"; then
        printf '%s — committed plan with no oracles needs "acceptance: none — <reason>" (done-claims are verifiable or explicitly waived)\n' "$rel"
        rc=1
    fi
    if [ "$state" = "superseded" ] && ! grep -q '^superseded-by: .' "$plan"; then
        printf '%s — superseded plan needs a "superseded-by: <where>" pointer (a state without a link is silence)\n' "$rel"
        rc=1
    fi
    if [ "$state" = "abandoned" ] && ! grep -q '^reason: .' "$plan"; then
        printf '%s — abandoned plan needs a "reason:" line\n' "$rel"
        rc=1
    fi
done
[ "$found" -eq 1 ] || exit 0
exit "$rc"
