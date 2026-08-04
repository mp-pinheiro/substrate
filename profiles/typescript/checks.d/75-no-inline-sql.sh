#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=../gate-lib.sh
source "$SUBSTRATE_DIR/gate-lib.sh"

files=()
mapfile -t files < <(profile_files typescript typescript)

[ ${#files[@]} -gt 0 ] || exit 0

out=$(sg_scan ts '$OBJ.execute($SQL)' "${files[@]}") || exit 0

SQL_FILTER='select((.metaVariables.single.SQL.text // "") | test("^[\"'\''`]\\s*(select|insert|update|delete|with)\\b"; "i"))'

FOUND=0
while IFS=$'\t' read -r f line; do
    [ -n "$f" ] || continue
    printf '%s:%s — inline SQL in .execute(...) — move SQL into the query layer\n' "$f" "$line"
    FOUND=1
done < <(jq -r "$SQL_FILTER | [.file, .range.start.line + 1] | @tsv" <<< "$out")

exit "$FOUND"
