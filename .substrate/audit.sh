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
    pass=0 pending=0 regressed=0 unverifiable=0 delegated=0 in_acceptance=0
    # On CI, matrix oracles delegate to the profile-matrix job (needs:
    # [gate, profile-matrix] guarantees all passed before this runs).
    delegate_matrix=0
    [ -n "${GITHUB_RUN_ID:-}" ] && delegate_matrix=1
    items=()
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
        items+=("$line")
    done < "$plan"

    # Partition: delegate matrix oracles on CI, keep the rest active
    active=()
    for ((i = 0; i < ${#items[@]}; i++)); do
        rest="${items[$i]:6}"
        cmd="${rest#* :: }"
        if [ "$delegate_matrix" -eq 1 ] && [[ "$cmd" == *"test/matrix.sh"* ]]; then
            printf '  [~~] %s — DELEGATED (profile-matrix CI)\n' "${rest%% :: *}"
            delegated=$((delegated + 1))
        else
            active+=("${items[$i]}")
        fi
    done

    n=${#active[@]}
    if [ "$n" -eq 0 ]; then
        printf '  audit: %d passing, %d pending, %d regressed, %d unverifiable, %d delegated\n' "$pass" "$pending" "$regressed" "$unverifiable" "$delegated"
        [ "$regressed" -eq 0 ] || overall_rc=1
        continue
    fi

    max_jobs=${SUBSTRATE_AUDIT_JOBS:-$(nproc 2>/dev/null || echo 4)}
    [ "$max_jobs" -lt 1 ] && max_jobs=1
    out_files=()
    rc_files=()
    wds=()
    running=0
    for ((i = 0; i < n; i++)); do
        rest="${active[$i]:6}"
        cmd="${rest#* :: }"
        out_files[$i]=$(mktemp)
        rc_files[$i]=$(mktemp)
        wds[$i]=$(mktemp -d)
        cp -r "$REPO_ROOT/." "${wds[$i]}/" 2>/dev/null
        ( cd "${wds[$i]}" && bash -c "$cmd" >"${out_files[$i]}" 2>&1; echo "$?" >"${rc_files[$i]}" ) &
        running=$((running + 1))
        if [ "$running" -ge "$max_jobs" ]; then
            wait -n 2>/dev/null || true
            running=$((running - 1))
        fi
    done

    for ((i = 0; i < n; i++)); do
        while [ ! -s "${rc_files[$i]}" ]; do sleep 0.1; done
        cmd_rc=$(cat "${rc_files[$i]}")
        line="${active[$i]}"
        box="${line:3:1}"
        rest="${line:6}"
        claim="${rest%% :: *}"
        cmd="${rest#* :: }"
        out=$(cat "${out_files[$i]}")
        rm -rf "${out_files[$i]}" "${rc_files[$i]}" "${wds[$i]}"
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
    wait 2>/dev/null
    printf '  audit: %d passing, %d pending, %d regressed, %d unverifiable, %d delegated\n' "$pass" "$pending" "$regressed" "$unverifiable" "$delegated"
    [ "$regressed" -eq 0 ] || overall_rc=1
done
exit "$overall_rc"
