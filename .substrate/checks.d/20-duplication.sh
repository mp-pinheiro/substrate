#!/usr/bin/env bash
# Copy/paste detection over claimed source files (jscpd). Ratcheted via dup_pct.
# Local jscpd binary preferred (offline-safe); bunx fallback fetches on a cold
# cache — absent locally = loud skip, absent in CI = fatal (toolchain broken).
set -uo pipefail
# shellcheck source=../gate-lib.sh
source "$SUBSTRATE_DIR/gate-lib.sh"

if command -v jscpd >/dev/null 2>&1; then
    JSCPD=(jscpd)
else
    require_bin_ci bunx "install bun: https://bun.sh (or: bun install -g jscpd)" || exit 0
    JSCPD=(bunx --yes jscpd)
fi

files=()
while IFS= read -r f; do
    scan_source "$f" && files+=("$f")
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
