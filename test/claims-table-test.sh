#!/usr/bin/env bash
# The runner-built claims table is an optimization, never a semantic change:
# claim, scan, and profile verdicts must match per-file fallback resolution
# for every inventory entry, including line/exempt-mode claims without ast_lang.
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'claims-table-test FAIL: %s\n' "$1" >&2; exit 1; }

T=$(mktemp -d) || fail "scratch dir"
trap 'rm -rf "$T"' EXIT
export HOME="$T/home" SUBSTRATE_NO_USER_HARNESS=1
mkdir -p "$HOME" "$T/repo"
cd "$T/repo" || exit 9
git init -q -b main
git config user.name substrate
git config user.email substrate@localhost
printf '#!/usr/bin/env bash\nprintf "owned\\n"\n' > owned.sh
printf 'print("py")\n' > tool.py
printf '#!/usr/bin/env python3\nprint("x")\n' > pytool
chmod +x owned.sh pytool
"$KIT_ROOT/bin/substrate" init --profile shell,python --vcs git >/dev/null 2>&1 || fail "init failed"
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

env -u CLAIMS bash -c "$verdict_script" > "$T/fallback.txt" || fail "fallback verdicts failed"

expected_max=0
while IFS= read -r line; do
    case "$line" in
        'y y '*)
            f=${line#y y ? }
            lines=$(wc -l < "$f")
            [ "$lines" -gt "$expected_max" ] && expected_max=$lines
            ;;
    esac
done < "$T/fallback.txt"
[ "$expected_max" -gt 3 ] || fail "fixture lost its line-mode workflow claims (expected_max=$expected_max)"

export SUBSTRATE_CLAIMS_OUT="$T/claims.tsv"
.substrate/gate.sh --update-baseline >/dev/null 2>&1 || fail "gate --update-baseline failed"
[ -s "$T/claims.tsv" ] || fail "runner did not produce a claims table"

grep -q "workflows/substrate-gate.yml" "$T/claims.tsv" \
    || fail "line-mode yml claim missing from the claims table"
CLAIMS="$T/claims.tsv" bash -c "$verdict_script" > "$T/table.txt" || fail "table verdicts failed"
diff -u "$T/fallback.txt" "$T/table.txt" > "$T/verdicts.diff" \
    || fail "table and fallback verdicts diverge: $(cat "$T/verdicts.diff")"

actual_max=$(jq -r '.metrics.max_file_lines' substrate-baseline.json)
[ "$actual_max" = "$expected_max" ] \
    || fail "budgets max under the table ($actual_max) diverges from fallback ($expected_max)"

printf 'claims-table-test: table/fallback parity across %s files green\n' "$(grep -c . "$INVENTORY")"
