#!/usr/bin/env bash
# The runner-built claims table is an optimization, never a semantic change:
# claim, scan, and profile verdicts must match per-file fallback resolution
# for every inventory entry, including line/exempt-mode claims without ast_lang.
# Each leg (bash, eventually go) runs in its own scratch dir; cmp between legs
# proves the claims table is engine-independent.
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'claims-table-test FAIL: %s\n' "$1" >&2; exit 1; }

ENGINES="${ENGINES:-bash}"
overall_rc=0
for ENGINE in $ENGINES; do
    export SUBSTRATE_ENGINE="$ENGINE"

    WORK=$(mktemp -d) || fail "$ENGINE scratch dir"
    trap 'rm -rf "$WORK"' EXIT
    export HOME="$WORK/home" SUBSTRATE_NO_USER_HARNESS=1 SUBSTRATE_VENDOR_FROM_WORKTREE=1
    mkdir -p "$HOME" "$WORK/repo"
    cd "$WORK/repo" || exit 9
    git init -q -b main
    git config user.name substrate
    git config user.email substrate@localhost
    printf '#!/usr/bin/env bash\nprintf "owned\\n"\n' > owned.sh
    printf 'print("py")\n' > tool.py
    printf '#!/usr/bin/env python3\nprint("x")\n' > pytool
    chmod +x owned.sh pytool
    "$KIT_ROOT/bin/substrate" init --profile shell,python --vcs git >/dev/null 2>&1 || fail "$ENGINE init failed"
    git add -A
    git commit -qm 'feat: seed'

    export SUBSTRATE_DIR="$PWD/.substrate"
    export REPO_ROOT="$PWD"
    export CONFIG="$PWD/substrate.json"
    export LANGMAP="$SUBSTRATE_DIR/langmap.json"
    export BASELINE="$PWD/substrate-baseline.json"
    INVENTORY=$(mktemp)
    METRICS=$(mktemp)
    export INVENTORY METRICS
    git ls-files > "$INVENTORY"

    verdict_script='
set -uo pipefail
source "$SUBSTRATE_DIR/gate-lib.sh"
while IFS= read -r f; do
    c=n; s=n; t=n
    claimed "$f" && c=y
    scan_source "$f" && s=y
    scan_target "$f" && t=y
    printf "%s %s %s %s\n" "$c" "$s" "$t" "$f"
done < "$INVENTORY"
printf "SHELL: %s\n" "$(profile_files shell | LC_ALL=C sort | tr "\n" " ")"
printf "PYTHON: %s\n" "$(profile_files python | LC_ALL=C sort | tr "\n" " ")"
'

    env -u CLAIMS bash -c "$verdict_script" > "$WORK/fallback.txt" || fail "$ENGINE fallback verdicts failed"

    expected_max=0
    while IFS= read -r line; do
        case "$line" in
            'y y '*)
                f=${line#y y ? }
                lines=$(wc -l < "$f")
                [ "$lines" -gt "$expected_max" ] && expected_max=$lines
                ;;
        esac
    done < "$WORK/fallback.txt"
    [ "$expected_max" -gt 3 ] || fail "$ENGINE fixture lost its line-mode workflow claims (expected_max=$expected_max)"

    export SUBSTRATE_CLAIMS_OUT="$WORK/claims.tsv"
    substrate-engine gate --update-baseline >/dev/null 2>&1 || fail "$ENGINE gate --update-baseline failed"
    [ -s "$WORK/claims.tsv" ] || fail "$ENGINE runner did not produce a claims table"

    grep -q "workflows/substrate-gate.yml" "$WORK/claims.tsv" \
        || fail "$ENGINE line-mode yml claim missing from the claims table"
    CLAIMS="$WORK/claims.tsv" bash -c "$verdict_script" > "$WORK/table.txt" || fail "$ENGINE table verdicts failed"
    diff -u "$WORK/fallback.txt" "$WORK/table.txt" > "$WORK/verdicts.diff" \
        || fail "$ENGINE table and fallback verdicts diverge: $(cat "$WORK/verdicts.diff")"

    actual_max=$(jq -r '.metrics.max_file_lines' substrate-baseline.json)
    [ "$actual_max" = "$expected_max" ] \
        || fail "$ENGINE budgets max under the table ($actual_max) diverges from fallback ($expected_max)"

    printf 'claims-table-test: %s leg table/fallback parity across %s files green\n' "$ENGINE" "$(grep -c . "$INVENTORY")"
done

if [ "$overall_rc" -eq 0 ]; then
    printf 'claims-table-test: %s leg(s) parity green\n' "$(echo "$ENGINES" | wc -w)"
else
    printf 'claims-table-test: %d leg(s) failed\n' "$overall_rc"
fi
exit "$overall_rc"
