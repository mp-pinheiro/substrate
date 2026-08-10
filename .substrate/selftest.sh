#!/usr/bin/env bash
# Negative-test battery in a sandbox copy of the repo. The gate is only
# trustworthy if it demonstrably goes red when attacked and hard-exits when
# its own machinery is corrupted — green-on-empty is the failure mode this
# file exists to make impossible.
set -uo pipefail

SUBSTRATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SUBSTRATE_DIR/.." && pwd)"
cd "$REPO_ROOT" || exit 2

PASS=0
FAIL=0
ok()   { printf '\033[0;32m[ok]\033[0m selftest: %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf '\033[0;31m[XX]\033[0m selftest: %s\n' "$*"; FAIL=$((FAIL + 1)); }
note() { printf '\033[0;34m[+]\033[0m selftest: %s\n' "$*"; }

if [ -d .jj ]; then
    listing=$(jj file list) || { echo "inventory failed"; exit 2; }
else
    listing=$(git ls-files) || { echo "inventory failed"; exit 2; }
fi

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

LIST="$SANDBOX/.filelist"
: > "$LIST"
while IFS= read -r f; do
    [ -f "$f" ] || continue
    cp --parents "$f" "$SANDBOX/"
    printf '%s\n' "$f" >> "$LIST"
done <<< "$listing"
cp -R .substrate "$SANDBOX/.substrate"
[ -f substrate.json ] && cp substrate.json "$SANDBOX/"
[ -f substrate-baseline.json ] && cp substrate-baseline.json "$SANDBOX/"

cd "$SANDBOX" || exit 2
export SUBSTRATE_FILE_LIST="$LIST"

# The sandbox has no .git, so history scanning is impossible; disable it visibly.
jq '.checks.disabled += ["50-gitleaks.sh"] | .checks.disabled |= unique' substrate.json > substrate.json.tmp \
    && mv substrate.json.tmp substrate.json
note "sandbox: 50-gitleaks.sh disabled (no .git)"

GATE="substrate-engine gate"

out=$($GATE 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then
    ok "steady state green"
else
    printf '%s\n' "$out"
    bad "steady state expected green, got rc=$rc"
fi

all_ran=1
for chk in .substrate/checks.d/*.sh; do
    name=$(basename "$chk")
    if ! grep -qF "$name" <<< "$out"; then
        bad "check $name left no trace in gate output — silent self-disable"
        all_ran=0
    fi
done
[ "$all_ran" -eq 1 ] && ok "every check reported (no silent self-disable)"

for pjson in .substrate/profiles/*/profile.json; do
    [ -f "$pjson" ] || continue
    pname=$(jq -r '.name' "$pjson")
    fixtures=$(jq -r '(.slop_fixtures // [])[]' "$pjson")
    if [ -z "$fixtures" ]; then
        if jq -e '[.claims // {} | to_entries[] | select(.value.mode != "exempt")] | length > 0' "$pjson" >/dev/null; then
            bad "profile $pname claims scannable files but has no slop_fixtures — cannot prove the comment gate bites"
        else
            note "profile $pname claims no scannable files — slop injection n/a"
        fi
        continue
    fi
    while IFS= read -r fixture_rel; do
        [ -n "$fixture_rel" ] || continue
        fixture="$(dirname "$pjson")/$fixture_rel"
        target="substrate-selftest-$(basename "$fixture")"
        cp "$fixture" "$target"
        printf '%s\n' "$target" >> "$LIST"
        out=$($GATE 2>&1)
        rc=$?
        if [ "$rc" -ne 0 ] && grep -qE "^$target:[0-9]+: (narration|restates-code|prose-block|todo-chatter|banner|step-numbering):" <<< "$out"; then
            ok "profile $pname: injected $(basename "$fixture") went red, named at the original path"
        else
            printf '%s\n' "$out"
            bad "profile $pname: injected $(basename "$fixture") rc=$rc (want red with a finding at $target)"
        fi
        rm -f "$target"
        grep -vF "$target" "$LIST" > "$LIST.tmp" && mv "$LIST.tmp" "$LIST"
    done <<< "$fixtures"
done

if jq -e '[to_entries[] | select(.value | type == "object")] | any(.value.mode == "ast")' .substrate/langmap.json >/dev/null; then
    SHIM=$(mktemp -d)
    printf '#!/usr/bin/env bash\nexit 1\n' > "$SHIM/ast-grep"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$SHIM/bunx"
    chmod +x "$SHIM/ast-grep" "$SHIM/bunx"
    out=$(PATH="$SHIM:$PATH" $GATE 2>&1)
    rc=$?
    if [ "$rc" -ne 0 ] && grep -q "cannot pass blind" <<< "$out"; then
        ok "broken detector tool goes red (cannot pass blind)"
    else
        printf '%s\n' "$out"
        bad "broken detector tool rc=$rc (want red with 'cannot pass blind')"
    fi
    rm -rf "$SHIM"
else
    note "no ast-mode claims — detector-break case skipped"
fi

had_baseline=0
[ -f substrate-baseline.json ] && { had_baseline=1; cp substrate-baseline.json baseline.bak; }
echo 'garbage' > substrate-baseline.json
$GATE >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 12 ]; then
    ok "corrupt baseline hard-exits (rc=12)"
else
    bad "corrupt baseline rc=$rc (want 12)"
fi
if [ "$had_baseline" -eq 1 ]; then mv baseline.bak substrate-baseline.json; else rm -f substrate-baseline.json; fi

cp .substrate/langmap.json langmap.bak
echo 'garbage' > .substrate/langmap.json
$GATE >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 12 ]; then
    ok "corrupt langmap hard-exits (rc=12)"
else
    bad "corrupt langmap rc=$rc (want 12)"
fi
mv langmap.bak .substrate/langmap.json

printf '\nselftest: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
