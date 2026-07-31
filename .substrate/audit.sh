#!/usr/bin/env bash
# Executes plan acceptance oracles (".pi/plans/*.md"). Every checked [x] item
# must still pass — a failure there is a regression and fails the audit. On
# plans in state "committed", every item must pass. Pending [ ] items on an
# active plan report status without failing: they are open work, not lies.
# Usage: audit.sh [plan.md ...]
set -uo pipefail

# vendored at <repo>/.substrate/audit.sh — parent dir is the repo root, so a
# subdirectory invocation cannot silently green-audit an empty plans dir
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLANS_DIR="$REPO_ROOT/.pi/plans"

plans=("$@")
if [ ${#plans[@]} -eq 0 ]; then
    [ -d "$PLANS_DIR" ] || { printf 'audit: no %s — nothing to verify\n' ".pi/plans"; exit 0; }
    while IFS= read -r f; do plans+=("$f"); done < <(find "$PLANS_DIR" -maxdepth 1 -name '*.md' | sort)
fi
[ ${#plans[@]} -gt 0 ] || { printf 'audit: no plans found\n'; exit 0; }

overall_rc=0
for plan in "${plans[@]}"; do
    [ -f "$plan" ] || { printf 'audit: %s: no such plan\n' "$plan" >&2; overall_rc=1; continue; }
    state=$(grep -m1 '^state: ' "$plan" | cut -d' ' -f2)
    case "$state" in
        superseded | abandoned)
            printf '=== %s (%s) — skipped\n' "$plan" "$state"
            continue
            ;;
        active | committed | draft) ;;
        *)
            printf 'audit: %s: missing or invalid "state:" line\n' "$plan" >&2
            overall_rc=1
            continue
            ;;
    esac

    printf '=== %s (%s)\n' "$plan" "$state"
    pass=0 pending=0 regressed=0 in_acceptance=0
    while IFS= read -r line; do
        case "$line" in
            '## Acceptance'*) in_acceptance=1; continue ;;
            '## '*) in_acceptance=0; continue ;;
        esac
        [ "$in_acceptance" -eq 1 ] || continue
        case "$line" in
            '- ['*']'*' :: '*) ;;
            *) continue ;;
        esac
        box="${line:3:1}"
        rest="${line:6}"
        claim="${rest%% :: *}"
        cmd="${rest#* :: }"
        out=$(cd "$REPO_ROOT" && bash -c "$cmd" 2>&1)
        if [ $? -eq 0 ]; then
            printf '  [ok] %s\n' "$claim"
            pass=$((pass + 1))
            [ "$box" = " " ] && printf '       ^ passing but unchecked — check the box\n'
        else
            if [ "$box" = "x" ] || [ "$state" = "committed" ]; then
                printf '  [XX] %s — REGRESSION (checked claim no longer holds)\n' "$claim"
                printf '       verify: %s\n' "$cmd"
                [ -n "$out" ] && printf '%s\n' "$out" | tail -5 | while IFS= read -r ol; do printf '       > %s\n' "$ol"; done
                regressed=$((regressed + 1))
            else
                printf '  [..] %s — pending\n' "$claim"
                pending=$((pending + 1))
            fi
        fi
    done < "$plan"
    printf '  audit: %d passing, %d pending, %d regressed\n' "$pass" "$pending" "$regressed"
    [ "$regressed" -eq 0 ] || overall_rc=1
done
exit "$overall_rc"
