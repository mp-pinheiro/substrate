#!/usr/bin/env bash
# Size budgets over claimed files. The metric is the repo-wide max; the ratchet
# means the biggest file can only shrink or hold. An absent budgets key is an
# error; opting out is an explicit, diff-visible `"max_file_lines": 0`.
set -uo pipefail
# shellcheck source=../gate-lib.sh
source "$SUBSTRATE_DIR/gate-lib.sh"

cap=$(cfg '.budgets.max_file_lines')
[ -n "$cap" ] || die_infra "budgets.max_file_lines is unset in substrate.json — set a cap, or 0 to opt out explicitly"
if [ "$cap" = "0" ]; then
    warn "budgets opted out in substrate.json (max_file_lines: 0)"
    exit 0
fi

max=0
max_file=""
while IFS= read -r f; do
    claimed "$f" || continue
    lines=$(wc -l < "$f") || die_infra "wc failed on $f"
    if [ "$lines" -gt "$max" ]; then
        max=$lines
        max_file=$f
    fi
done < "$INVENTORY"

metric max_file_lines "$max"

if [ "$max" -gt "$cap" ]; then
    printf '%s: %d lines exceeds the hard cap %d — split it (budgets.max_file_lines in substrate.json)\n' "$max_file" "$max" "$cap"
    exit 1
fi
exit 0
