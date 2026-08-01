#!/usr/bin/env bash
# Per-profile oracle: every kit profile must prove itself in a scratch repo —
# init, green infra, baseline, then the full selftest battery (which injects
# each slop fixture and requires red). A profile no repo has run is a profile
# that does not ship.
# Usage: matrix.sh [profile...]   (default: every profiles/*/)
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# scratch inits must never touch the live user harness (~/.claude, ~/.omp)
export SUBSTRATE_NO_USER_HARNESS=1

PASS=0
FAIL=0
ok()  { printf '\033[0;32m[ok]\033[0m matrix %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '\033[0;31m[XX]\033[0m matrix %s\n' "$*"; FAIL=$((FAIL + 1)); }

profiles=("$@")
if [ ${#profiles[@]} -eq 0 ]; then
    mapfile -t profiles < <(basename -a "$KIT_ROOT"/profiles/*/)
fi

for name in "${profiles[@]}"; do
    pdir="$KIT_ROOT/profiles/$name"
    [ -d "$pdir" ] || { bad "$name: no such kit profile"; continue; }

    tmp=$(mktemp -d)
    (
        set -uo pipefail
        cd "$tmp" || exit 9
        git init -q
        git config user.email substrate@localhost
        git config user.name substrate

        printf '# substrate matrix scratch repo\n' > README.md
        for s in "$pdir"/fixtures/clean.* "$pdir"/fixtures/clean-*; do
            [ -f "$s" ] || continue
            base=$(basename "$s")
            case "$base" in
                clean-*) dest="${base#clean-}" ;;
                clean.*) dest="sample.${base#clean.}" ;;
                *) continue ;;
            esac
            mkdir -p "$(dirname "./$dest")"
            cp "$s" "./$dest"
        done

        git add -A
        git commit -qm seed

        "$KIT_ROOT/bin/substrate" init --profile "$name" >/dev/null 2>&1 || { echo "init failed"; exit 9; }
        jq '.report.max_age_days = 0' substrate.json > s.tmp && mv s.tmp substrate.json
        git add -A && git commit -qm init

        out=$(.substrate/gate.sh --update-baseline 2>&1)
        rc=$?
        if [ "$rc" -ne 0 ]; then
            printf '%s\n' "$out"
            echo "gate --update-baseline failed (rc=$rc)"
            exit 9
        fi
        out=$(.substrate/selftest.sh 2>&1)
        rc=$?
        if [ "$rc" -ne 0 ]; then
            printf '%s\n' "$out"
            echo "selftest failed (rc=$rc)"
            exit 9
        fi

        tool_ok=1
        while IFS= read -r bin; do
            [ -n "$bin" ] || continue
            command -v "$bin" >/dev/null 2>&1 || tool_ok=0
        done < <(jq -r '(.toolchain // [])[].bin' "$pdir/profile.json")

        while IFS=$'\t' read -r bad_rel fails_check bad_dest; do
            [ -n "$bad_rel" ] || continue
            if [ "$tool_ok" -eq 0 ]; then
                if [ -n "${CI:-}" ]; then
                    echo "own-check oracle CANNOT RUN: toolchain missing in CI for $fails_check — install steps are broken"
                    exit 9
                fi
                echo "note: toolchain absent — bad-fixture assertion for $fails_check skipped locally (CI enforces)"
                continue
            fi
            src="$pdir/$bad_rel"
            if [ -z "$bad_dest" ]; then
                bad_dest="substrate-matrix-bad-$(basename "$bad_rel")"
            fi
            mkdir -p "$(dirname "./$bad_dest")" 2>/dev/null || true
            if [ -d "$src" ]; then
                cp -R "$src/." "./$bad_dest/" 2>/dev/null || cp -R "$src" "./$bad_dest"
            else
                cp "$src" "./$bad_dest"
            fi
            git add -A && git commit -qm bad-fixture
            out=$(.substrate/gate.sh 2>&1)
            rc=$?
            if [ "$rc" -ne 0 ] && grep -qF "$fails_check" <<< "$out"; then
                echo "own-check oracle: $fails_check rejected $(basename "$bad_rel")"
            else
                printf '%s\n' "$out"
                echo "own-check oracle FAILED: $fails_check did not reject $bad_rel (rc=$rc)"
                exit 9
            fi
            if [ "$bad_dest" = "." ]; then
                git reset -q --hard HEAD^
            else
                rm -rf "./${bad_dest:?}"
                git add -A && git commit -qm bad-fixture-removed
            fi
        done < <(jq -r '(.check_fixtures // [])[] | "\(.file)\t\(.fails)\t\(.dest // "")"' "$pdir/profile.json")

        if jq -e '(.checks // []) | length > 0' "$pdir/profile.json" >/dev/null \
            && ! jq -e '(.check_fixtures // []) | length > 0' "$pdir/profile.json" >/dev/null; then
            echo "profile ships checks but no check_fixtures — its checks have no oracle"
            exit 9
        fi
    )
    case $? in
        0) ok "$name: init + baseline + selftest green" ;;
        *) bad "$name: see output above" ;;
    esac
    rm -rf "$tmp"
done

printf '\nmatrix: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
