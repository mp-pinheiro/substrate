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

delegate_matrix=0
[ -n "${GITHUB_RUN_ID:-}" ] && delegate_matrix=1
max_jobs=${SUBSTRATE_AUDIT_JOBS:-$(nproc 2>/dev/null || echo 4)}
[ "$max_jobs" -lt 1 ] && max_jobs=1
unset SUBSTRATE_VENDOR_FROM_WORKTREE
results=$(mktemp -d) || exit 2
trap 'rm -rf "$results"' EXIT

declare -A slot_of
slots=0
running=0
launch() {
    local cmd="$1" slot="$slots"
    slot_of["$cmd"]=$slot
    slots=$((slots + 1))
    : >"$results/$slot.out"
    (
        wd=$(mktemp -d) || { echo 2 >"$results/$slot.rc"; exit 0; }
        cp -r "$REPO_ROOT/." "$wd/" 2>/dev/null
        cd "$wd" && bash -c "$cmd" >"$results/$slot.out" 2>&1
        rc=$?
        cd / && rm -rf "$wd"
        echo "$rc" >"$results/$slot.rc"
    ) &
    running=$((running + 1))
    if [ "$running" -ge "$max_jobs" ]; then
        wait -n 2>/dev/null || true
        running=$((running - 1))
    fi
}

plan_state=()
item_plan=()
item_line=()
item_delegated=()
for ((p = 0; p < ${#plans[@]}; p++)); do
    plan="${plans[$p]}"
    [ -f "$plan" ] || { plan_state[p]=missing; continue; }
    state=$(grep -m1 '^state: ' "$plan" | cut -d' ' -f2)
    plan_state[p]=$state
    case "$state" in
        active | committed | draft) ;;
        *) continue ;;
    esac
    in_acceptance=0
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
        item_plan+=("$p")
        item_line+=("$line")
        rest="${line:6}"
        cmd="${rest#* :: }"
        if [ "$delegate_matrix" -eq 1 ] && [[ "$cmd" == *"test/matrix.sh"* ]]; then
            item_delegated+=(1)
        else
            item_delegated+=(0)
            [ -n "${slot_of[$cmd]+set}" ] || launch "$cmd"
        fi
    done < "$plan"
done

overall_rc=0
for ((p = 0; p < ${#plans[@]}; p++)); do
    plan="${plans[$p]}"
    state="${plan_state[$p]}"
    case "$state" in
        missing)
            printf 'audit: %s: no such plan\n' "$plan" >&2
            overall_rc=1
            continue
            ;;
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
    pass=0 pending=0 regressed=0 unverifiable=0 delegated=0
    active=()
    for ((i = 0; i < ${#item_line[@]}; i++)); do
        [ "${item_plan[$i]}" -eq "$p" ] || continue
        if [ "${item_delegated[$i]}" -eq 1 ]; then
            rest="${item_line[$i]:6}"
            printf '  [~~] %s — DELEGATED (profile-matrix CI)\n' "${rest%% :: *}"
            delegated=$((delegated + 1))
        else
            active+=("${item_line[$i]}")
        fi
    done

    for ((i = 0; i < ${#active[@]}; i++)); do
        line="${active[$i]}"
        box="${line:3:1}"
        rest="${line:6}"
        claim="${rest%% :: *}"
        cmd="${rest#* :: }"
        slot="${slot_of[$cmd]}"
        while [ ! -s "$results/$slot.rc" ]; do sleep 0.1; done
        cmd_rc=$(cat "$results/$slot.rc")
        out=$(cat "$results/$slot.out")
        if [ "$cmd_rc" -eq 0 ]; then
            printf '  [ok] %s\n' "$claim"
            pass=$((pass + 1))
            [ "$box" = " " ] && printf '       ^ passing but unchecked — check the box\n'
        elif [ "$cmd_rc" -eq 3 ]; then
            printf '  [--] %s — UNVERIFIABLE (no credentials/offline)\n' "$claim"
            unverifiable=$((unverifiable + 1))
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
    done
    printf '  audit: %d passing, %d pending, %d regressed, %d unverifiable, %d delegated\n' "$pass" "$pending" "$regressed" "$unverifiable" "$delegated"
    [ "$regressed" -eq 0 ] || overall_rc=1
done
wait 2>/dev/null
exit "$overall_rc"
