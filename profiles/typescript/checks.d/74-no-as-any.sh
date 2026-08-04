#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=../gate-lib.sh
source "$SUBSTRATE_DIR/gate-lib.sh"

files=()
mapfile -t files < <(profile_files typescript typescript)

[ ${#files[@]} -gt 0 ] || exit 0

out=$(sg_scan ts '$X as any' "${files[@]}") || exit 0

FOUND=0
while IFS=$'\t' read -r f line; do
    [ -n "$f" ] || continue
    printf '%s:%s — as any — type the value or use unknown + narrowing\n' "$f" "$line"
    FOUND=1
done < <(jq -r '. | [.file, .range.start.line + 1] | @tsv' <<< "$out")

exit "$FOUND"
