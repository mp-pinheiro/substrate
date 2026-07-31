#!/usr/bin/env bash
# Banned TypeScript constructs via ast-grep, each finding carrying a
# corrective pointer. Resolution mirrors the comment gate: binary, else bunx.
set -uo pipefail
# shellcheck source=../gate-lib.sh
source "$SUBSTRATE_DIR/gate-lib.sh"

files=()
mapfile -t files < <(profile_files typescript typescript)

[ ${#files[@]} -gt 0 ] || exit 0

SG=()
if have ast-grep; then
    SG=(ast-grep)
elif have bunx; then
    SG=(bunx --yes @ast-grep/cli)
elif [ -n "${CI:-}" ]; then
    die_infra "ast-grep unavailable in CI (install @ast-grep/cli or bun) — cannot pass blind"
else
    warn "ast-grep unavailable — constructs check skipped locally, CI runs it"
    exit 0
fi

# sg_json <pattern> <jq-select> — matches as "file<TAB>1-based-line"; gate:allow-comment
# infra rc propagates through the command substitution at each call site.
sg_json() {
    local pat="$1" filter="$2" errf out rc
    errf=$(mktemp)
    out=$("${SG[@]}" run --lang ts --pattern "$pat" --json=stream "${files[@]}" 2>"$errf")
    rc=$?
    if [ "$rc" -eq 1 ] && [ -z "$out" ]; then
        rm -f "$errf"
        return 0
    fi
    if [ "$rc" -ne 0 ]; then
        cat "$errf" >&2
        rm -f "$errf"
        die_infra "ast-grep failed on pattern '$pat' (rc=$rc) — cannot pass blind"
    fi
    rm -f "$errf"
    jq -r "$filter | [.file, .range.start.line + 1] | @tsv" <<< "$out" \
        || die_infra "ast-grep emitted unparseable JSON for pattern '$pat'"
}

FOUND=0

matches=$(sg_json 'throw new Error($$$ARGS)' '.') || exit $?
while IFS=$'\t' read -r f line; do
    [ -n "$f" ] || continue
    case "$f" in
        errors.ts | */errors.ts | errors/* | */errors/*) continue ;;
    esac
    printf '%s:%s — raw throw new Error(...) — use the repo error module (errors.ts) instead of raw Error\n' "$f" "$line"
    FOUND=1
done <<< "$matches"

matches=$(sg_json '$X as any' '.') || exit $?
while IFS=$'\t' read -r f line; do
    [ -n "$f" ] || continue
    printf '%s:%s — as any — type the value or use unknown + narrowing\n' "$f" "$line"
    FOUND=1
done <<< "$matches"

SQL_FILTER='select((.metaVariables.single.SQL.text // "") | test("^[\"'\''`]\\s*(select|insert|update|delete|with)\\b"; "i"))'
matches=$(sg_json '$OBJ.execute($SQL)' "$SQL_FILTER") || exit $?
while IFS=$'\t' read -r f line; do
    [ -n "$f" ] || continue
    printf '%s:%s — inline SQL in .execute(...) — move SQL into the query layer\n' "$f" "$line"
    FOUND=1
done <<< "$matches"

exit "$FOUND"
