#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=../gate-lib.sh
source "$SUBSTRATE_DIR/gate-lib.sh"

ts_files=()
mapfile -t ts_files < <(profile_files typescript typescript)
tsx_files=()
mapfile -t tsx_files < <(profile_files typescript tsx)

[ $((${#ts_files[@]} + ${#tsx_files[@]})) -gt 0 ] || exit 0

SG=()
resolve_sg

asserts_any='constraints:
  T:
    any:
      - kind: predefined_type
        regex: ^any$
      - has:
          kind: predefined_type
          regex: ^any$
          stopBy: end
'
ts_rule='id: no-as-any
language: TypeScript
rule:
  any:
    - pattern: $X as $T
    - pattern: <$T>$X
'"$asserts_any"
tsx_rule='id: no-as-any
language: Tsx
rule:
  pattern: $X as $T
'"$asserts_any"

scan_any() {
    local rule="$1"; shift
    SCAN_OUT=$("${SG[@]}" scan --inline-rules "$rule" --json=compact "$@")
    jq -e 'type == "array"' <<< "$SCAN_OUT" >/dev/null \
        || die_infra "ast-grep produced no JSON for the any-assertion rule — cannot scan blind"
}

ts_out='[]'
if [ ${#ts_files[@]} -gt 0 ]; then
    scan_any "$ts_rule" "${ts_files[@]}"
    ts_out=$SCAN_OUT
fi
tsx_out='[]'
if [ ${#tsx_files[@]} -gt 0 ]; then
    scan_any "$tsx_rule" "${tsx_files[@]}"
    tsx_out=$SCAN_OUT
fi

FOUND=0
while IFS=$'\t' read -r f line; do
    [ -n "$f" ] || continue
    printf '%s:%s — as any — type the value or use unknown + narrowing\n' "$f" "$line"
    FOUND=1
done < <(jq -r '.[] | [.file, .range.start.line + 1] | @tsv' <(printf '%s' "$ts_out") <(printf '%s' "$tsx_out"))

exit "$FOUND"
