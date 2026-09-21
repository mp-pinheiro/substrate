#!/usr/bin/env bash
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$KIT_ROOT/test/lib/scratch-repo-fixture.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"
scratch_repo_init "$REPO" airflow || exit 1

helper="$REPO/.substrate/import-linter-check.sh"
wrapper="$REPO/.substrate/checks.d/62-import-linter.sh"
[ -f "$helper" ] || { printf 'import-linter-packaging-test: shared helper not vendored\n' >&2; exit 1; }
[ -f "$wrapper" ] || { printf 'import-linter-packaging-test: airflow wrapper not vendored\n' >&2; exit 1; }

: > "$WORK/inventory"
: > "$WORK/claims"
: > "$WORK/metrics"
printf '{}\n' > "$WORK/baseline"
run_wrapper() {
    REPO_ROOT="$REPO" SUBSTRATE_DIR="$REPO/.substrate" CONFIG="$REPO/substrate.json" \
        LANGMAP="$REPO/.substrate/langmap.json" INVENTORY="$WORK/inventory" CLAIMS="$WORK/claims" \
        METRICS="$WORK/metrics" BASELINE="$WORK/baseline" bash "$wrapper"
}
run_wrapper || { printf 'import-linter-packaging-test: airflow-only wrapper did not load shared helper\n' >&2; exit 1; }
rm "$helper"
out=$(run_wrapper 2>&1)
rc=$?
if [ "$rc" -ne 3 ] || [[ "$out" != *"import-linter implementation missing"* ]]; then
    printf '%s\n' "$out"
    printf 'import-linter-packaging-test: missing helper returned %d, want infrastructure exit 3\n' "$rc" >&2
    exit 1
fi
printf 'import-linter-packaging-test: airflow-only helper packaging and failure classification green\n'
