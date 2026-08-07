#!/usr/bin/env bash
# Battery runner: selects suites, runs them concurrently, reports per-suite wall time.
# Usage: test/run.sh [--only a,b,...] [--jobs N] [--list]
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$KIT_ROOT" || exit 2
# suites vendor from the checkout under test, by definition
export SUBSTRATE_VENDOR_FROM_WORKTREE=1

# Explicit, never a glob: test/ also holds capture-*.sh, which REWRITE frozen vectors.
SUITES=(
    ab-hooks-test ab-stop-test baseline-test bootstrap-test changed-scan-test
    checkpoint-test claims-table-test contract-drift-test doctor-attestation-test
    engine-rollback-test gitleaks-deep-test gitleaks-scope-test golden-ledger-test
    golden-vectors-test init-idempotent-test maintenance-test parity-test
    receipt-cross-engine-test receipt-test restructure-test vcs-hooks-test
    vendor-drift-test vendor-source-test
)

# gitleaks costs ~4.7s of fixed rule compilation per invocation (measured on an EMPTY dir)
# and every fixture gate pays it; elsewhere the check's own `have gitleaks || skip` fires.
KEEP_GITLEAKS=" gitleaks-deep-test gitleaks-scope-test golden-vectors-test claims-table-test baseline-test "

only=""
jobs=$(nproc 2>/dev/null || printf '4')
while [ "$#" -gt 0 ]; do
    case "$1" in
        --only) only="$2"; shift 2 ;;
        --only=*) only="${1#--only=}"; shift ;;
        --jobs) jobs="$2"; shift 2 ;;
        --jobs=*) jobs="${1#--jobs=}"; shift ;;
        --list) printf '%s\n' "${SUITES[@]}"; exit 0 ;;
        *) printf 'usage: %s [--only a,b] [--jobs N] [--list]\n' "$0" >&2; exit 2 ;;
    esac
done

selected=()
if [ -n "$only" ]; then
    IFS=, read -r -a want <<< "$only"
    for w in "${want[@]}"; do
        [ -n "$w" ] || continue
        if [ -f "test/$w.sh" ]; then selected+=("$w")
        else printf 'no such suite: %s\n' "$w" >&2; exit 2; fi
    done
else
    selected=("${SUITES[@]}")
fi

run_dir=$(mktemp -d) || exit 2
trap 'rm -rf "$run_dir"' EXIT

# Dropping the whole PATH entry would take its ~130 siblings (shellcheck, actionlint)
# with it, so re-expose them as symlinks and omit only gitleaks itself.
shim="$run_dir/nogl-bin"
mkdir -p "$shim" || exit 2
nogl_path=""
IFS=: read -r -a path_parts <<< "$PATH"
for d in "${path_parts[@]}"; do
    if [ -x "$d/gitleaks" ]; then
        for f in "$d"/*; do
            b=$(basename "$f")
            [ "$b" = gitleaks ] && continue
            [ -x "$f" ] && [ ! -e "$shim/$b" ] && ln -s "$f" "$shim/$b"
        done
        continue
    fi
    nogl_path="${nogl_path:+$nogl_path:}$d"
done
nogl_path="$shim:$nogl_path"

started=$(date +%s%N)
running=0
for s in "${selected[@]}"; do
    (
        suite_path="$PATH"
        case "$KEEP_GITLEAKS" in *" $s "*) ;; *) suite_path="$nogl_path" ;; esac
        t0=$(date +%s%N)
        env PATH="$suite_path" bash "test/$s.sh" > "$run_dir/$s.out" 2>&1
        rc=$?
        t1=$(date +%s%N)
        printf '%s %s\n' "$rc" $(( (t1 - t0) / 1000000 )) > "$run_dir/$s.rc"
    ) &
    running=$((running + 1))
    if [ "$running" -ge "$jobs" ]; then wait -n 2>/dev/null || wait; running=$((running - 1)); fi
done
wait
elapsed=$(( ($(date +%s%N) - started) / 1000000 ))

failed=0
printf '\n'
for s in "${selected[@]}"; do
    read -r rc ms < "$run_dir/$s.rc" 2>/dev/null || { rc=70; ms=0; }
    if [ "$rc" -eq 0 ]; then
        printf '[ok]   %-28s %6d ms\n' "$s" "$ms"
    else
        printf '[FAIL] %-28s %6d ms  (rc=%s)\n' "$s" "$ms" "$rc"
        failed=$((failed + 1))
    fi
done
if [ "$failed" -gt 0 ]; then
    printf '\n--- output of failing suites ---\n'
    for s in "${selected[@]}"; do
        read -r rc _ < "$run_dir/$s.rc" 2>/dev/null || rc=70
        [ "$rc" -eq 0 ] && continue
        printf '\n===== %s\n' "$s"
        tail -25 "$run_dir/$s.out"
    done
fi
printf '\nbattery: %s suite(s), %s failed, %d ms wall\n' "${#selected[@]}" "$failed" "$elapsed"
[ "$failed" -eq 0 ]
