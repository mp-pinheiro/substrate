#!/usr/bin/env bash
# Kit-repo guard: the vendored .substrate must match its sources exactly.
# Drift means an edit landed on the wrong side and would be masked or lost —
# the gate and selftest execute the VENDORED copy, so green there proves
# nothing about core/ unless this check holds.
set -uo pipefail
# shellcheck source=../core/gate-lib.sh
source "$SUBSTRATE_DIR/gate-lib.sh"

rc=0
pair() {
    local src="$1" vendored="$2"
    if [ ! -f "$src" ]; then
        printf '%s exists vendored but its source %s is gone — restore the source\n' "$vendored" "$src"
        rc=1
        return
    fi
    if ! cmp -s "$src" "$vendored"; then
        printf '%s drifted from %s — run: substrate update --apply (or fix the source side)\n' "$vendored" "$src"
        rc=1
    fi
}

for f in gate.sh gate-lib.sh check-comments.sh comment-ratchet.sh selftest.sh audit.sh report.sh; do
    pair "core/$f" "$SUBSTRATE_DIR/$f"
done
if [ -f ".omp/extensions/substrate-quality.ts" ]; then
    pair "core/omp/substrate-quality.ts" ".omp/extensions/substrate-quality.ts"
fi
if [ -f "docs/jj-workflow.md" ]; then
    pair "core/jj-workflow.md" "docs/jj-workflow.md"
fi
if [ -f "profiles/airflow/checks.d/62-import-linter.sh" ]; then
    pair "profiles/python/checks.d/62-import-linter.sh" "profiles/airflow/checks.d/62-import-linter.sh"
fi
for f in core/hooks/*.sh; do
    [ -f "$f" ] && pair "$f" "$SUBSTRATE_DIR/hooks/$(basename "$f")"
done
for f in core/checks.d/*.sh; do
    [ -f "$f" ] && pair "$f" "$SUBSTRATE_DIR/checks.d/$(basename "$f")"
done
mapfile -t ACTIVE < <(jq -r '(.profiles // [])[]' "$CONFIG")
for f in profiles/*/checks.d/*.sh substrate-profiles/*/checks.d/*.sh; do
    [ -f "$f" ] || continue
    p=$(basename "$(dirname "$(dirname "$f")")")
    printf '%s\n' "${ACTIVE[@]}" | grep -qxF "$p" || continue
    pair "$f" "$SUBSTRATE_DIR/checks.d/$(basename "$f")"
done
for f in checks.d/*.sh; do
    [ -f "$f" ] && pair "$f" "$SUBSTRATE_DIR/checks.d/$(basename "$f")"
done

exit "$rc"
