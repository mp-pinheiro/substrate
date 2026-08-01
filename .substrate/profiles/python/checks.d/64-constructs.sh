#!/usr/bin/env bash
# Banned-construct gate, matched structurally with ast-grep: inline SQL
# outside the query layer, and silent exception swallowing.
set -uo pipefail
# shellcheck source=../gate-lib.sh
source "$SUBSTRATE_DIR/gate-lib.sh"

files=()
mapfile -t files < <(profile_files_ext python .py)

[ ${#files[@]} -gt 0 ] || exit 0

SG=()
if have ast-grep; then
    SG=(ast-grep)
elif have bunx; then
    SG=(bunx --yes @ast-grep/cli@0.45.0)
else
    die_infra "ast-grep unavailable (install ast-grep, or bun for bunx) — cannot scan constructs blind"
fi

# ast-grep run exits 1 on zero matches, so rc is meaningless — a parseable gate:allow-comment
# JSON array on stdout is the only reliable success signal.
sql1=$("${SG[@]}" run --pattern 'cursor.execute($SQL)' --lang python --json=compact "${files[@]}")
jq -e 'type == "array"' <<< "$sql1" >/dev/null \
    || die_infra "ast-grep produced no JSON for the 1-arg execute pattern — cannot scan constructs blind"
sql2=$("${SG[@]}" run --pattern 'cursor.execute($SQL, $$$REST)' --lang python --json=compact "${files[@]}")
jq -e 'type == "array"' <<< "$sql2" >/dev/null \
    || die_infra "ast-grep produced no JSON for the n-arg execute pattern — cannot scan constructs blind"
swallow=$("${SG[@]}" run --pattern 'try:
    $$$BODY
except Exception:
    pass' --lang python --json=compact "${files[@]}")
jq -e 'type == "array"' <<< "$swallow" >/dev/null \
    || die_infra "ast-grep produced no JSON for the except-pass pattern — cannot scan constructs blind"

report=""
sql_re="^[bBrRuUfF]*[\"']{1,3}[[:space:]]*(SELECT|INSERT|UPDATE|DELETE)([^A-Za-z0-9_]|\$)"
while IFS=$'\t' read -r f line sqltext; do
    [ -n "$f" ] || continue
    case "$f" in
        db/*|*/db/*|queries.py|*/queries.py) continue ;;
    esac
    [[ "$sqltext" =~ $sql_re ]] || continue
    report+="$f:$line — inline SQL literal in cursor.execute — move SQL into the query layer (db/ or queries.py)"$'\n'
done < <(jq -r '.[] | [.file, (.range.start.line + 1), (.metaVariables.single.SQL.text // "")] | @tsv' \
    <(printf '%s' "$sql1") <(printf '%s' "$sql2"))

while IFS=$'\t' read -r f line; do
    [ -n "$f" ] || continue
    report+="$f:$line — except Exception: pass — handle or re-raise; silent except is banned"$'\n'
done < <(jq -r '.[] | [.file, (.range.start.line + 1)] | @tsv' <<< "$swallow")

if [ -n "$report" ]; then
    printf '%s' "$report"
    exit 1
fi
exit 0
