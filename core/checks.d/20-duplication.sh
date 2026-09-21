#!/usr/bin/env bash
# Copy/paste detection over claimed source files (jscpd). Ratcheted via dup_pct.
set -uo pipefail
# shellcheck source=../gate-lib.sh
source "$SUBSTRATE_DIR/gate-lib.sh"

if command -v jscpd >/dev/null 2>&1; then
    JSCPD=(jscpd)
else
    require_bin bunx "install bun: https://bun.sh (or: bun install -g jscpd@5.0.14)"
    JSCPD=(bunx --yes jscpd@5.0.14)
fi
version_out=$("${JSCPD[@]}" --version 2>&1)
version_rc=$?
if [ "$version_rc" -ne 0 ]; then
    die_infra "jscpd version probe failed (rc=$version_rc) — install jscpd 5.0.14"
fi
case "$version_out" in
    "cpd 5.0.14"|"jscpd 5.0.14"|"5.0.14") ;;
    *) die_infra "jscpd 5.0.14 is required, found: $version_out" ;;
esac

files=()
# Managed files are generated mirrors; their canonical source remains in scope.
while IFS= read -r f; do
    scan_source "$f" || continue
    IFS= read -r first < "$f" || first=""
    [ "$first" = "# substrate-managed" ] && continue
    files+=("$f")
done < "$INVENTORY"
[ ${#files[@]} -eq 0 ] && exit 0

min_tokens=$(cfg '.duplication.min_tokens')
[ -n "$min_tokens" ] || min_tokens=35

report_dir=$(mktemp -d)
out=$("${JSCPD[@]}" --min-tokens "$min_tokens" --reporters json --output "$report_dir" "${files[@]}" 2>&1)
rc=$?
pct=$(jq -r '.statistics.total.percentage // 0' "$report_dir/jscpd-report.json" 2>/dev/null)
rm -rf "$report_dir"

if [ "$rc" -ne 0 ] || [ -z "$pct" ] || [ "$pct" = "null" ]; then
    printf '%s\n' "$out"
    die_infra "jscpd failed (rc=$rc) — the gate cannot pass blind"
fi

metric dup_pct "$pct"
exit 0
