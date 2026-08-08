#!/usr/bin/env bash
# Comment-slop ratchet: per-file counts become metrics; the runner enforces the
# baseline. Findings are printed only for files above their current allowance,
# so grandfathered debt stays quiet and new slop is loud.
set -uo pipefail
# shellcheck source=../gate-lib.sh
source "$SUBSTRATE_DIR/gate-lib.sh"

files=()
while IFS= read -r f; do
    scan_target "$f" && files+=("$f")
done < "$INVENTORY"
[ ${#files[@]} -eq 0 ] && exit 0

out=$("$SUBSTRATE_DIR/check-comments.sh" "${files[@]}")
rc=$?
if [ "$rc" -ge 2 ]; then
    printf '%s\n' "$out"
    exit "$rc"
fi

if [ "$rc" -eq 0 ]; then
    counts='{}'
else
    counts=$(printf '%s\n' "$out" | jq -Rr 'capture("^(?<f>.+?):[0-9]+: ") | .f' | sort | uniq -c \
        | jq -Rn '[inputs | capture("^ *(?<n>[0-9]+) (?<f>.+)$")] | map({(.f): (.n | tonumber)}) | add // {}') \
        || die_infra "comment count aggregation failed"
fi

while IFS=$'\t' read -r f n; do
    [ -n "$f" ] && metric "comments:$f" "$n"
done < <(jq -r 'to_entries[] | "\(.key)\t\(.value)"' <<< "$counts")

if [ -f "$BASELINE" ]; then
    base=$(jq -c '.metrics // {}' "$BASELINE") || die_infra "cannot read baseline metrics"
    over=$(jq -rn --argjson c "$counts" --argjson b "$base" \
        '$c | to_entries[] | select(.value > (($b["comments:" + .key]) // 0)) | .key') \
        || die_infra "comment baseline comparison failed"
    if [ -n "$over" ]; then
        while IFS= read -r f; do
            printf '%s\n' "$out" | grep -F "$f:"
        done <<< "$over"
        printf 'comment gate: remove the flagged comments or encode the fact in names/structure.\n'
        printf 'A rare keeper may stay: append "gate:allow-comment" to the line.\n'
        exit 1
    fi
fi

exit 0
