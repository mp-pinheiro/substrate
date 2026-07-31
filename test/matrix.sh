#!/usr/bin/env bash
# Per-profile oracle: every kit profile must prove itself in a scratch repo —
# init, green infra, baseline, then the full selftest battery (which injects
# each slop fixture and requires red). A profile no repo has run is a profile
# that does not ship.
# Usage: matrix.sh [profile...]   (default: every profiles/*/)
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

        found_clean=0
        for s in "$pdir"/fixtures/clean.* "$pdir"/fixtures/clean-*; do
            [ -f "$s" ] || continue
            cp "$s" "./$(basename "$s" | cut -c7-)"
            found_clean=1
        done
        if [ "$found_clean" -eq 0 ]; then
            echo "no fixtures/clean.* sample — the scratch repo would be empty"
            exit 9
        fi

        git add -A
        git commit -qm seed

        "$KIT_ROOT/bin/substrate" init --profile "$name" >/dev/null 2>&1 || { echo "init failed"; exit 9; }
        jq '.checks.disabled += ["50-gitleaks.sh"] | .checks.disabled |= unique' substrate.json > s.tmp && mv s.tmp substrate.json
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
    )
    case $? in
        0) ok "$name: init + baseline + selftest green" ;;
        *) bad "$name: see output above" ;;
    esac
    rm -rf "$tmp"
done

printf '\nmatrix: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
