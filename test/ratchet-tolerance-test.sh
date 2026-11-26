#!/usr/bin/env bash
set -uo pipefail

fail() { printf 'ratchet-tolerance-test FAIL: %s\n' "$1" >&2; exit 1; }

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/scratch-repo-fixture.sh
source "$KIT_ROOT/test/lib/scratch-repo-fixture.sh"
T=$(mktemp -d) || fail "scratch dir"
trap 'rm -rf "$T"' EXIT

scratch_repo_init "$T/repo" shell || fail "init failed"

shared_block() {
    cat <<'SH'
report_status() {
    local label="$1" state="$2" detail="$3"
    if [ "$state" = ok ]; then
        printf '[ok] %s: %s\n' "$label" "$detail"
        return 0
    fi
    if [ "$state" = skip ]; then
        printf '[--] %s: %s\n' "$label" "$detail"
        return 0
    fi
    printf '[!!] %s: %s\n' "$label" "$detail" >&2
    return 1
}
SH
}

unique_lines() {
    local count="$1" i
    for ((i = 1; i <= count; i++)); do
        printf 'printf "%%s\\n" "filler entry %d of %d"\n' "$i" "$((i * 7 + 3))"
    done
}

{ printf '#!/usr/bin/env bash\nset -euo pipefail\n'; shared_block; printf 'report_status first ok ready\n'; } > first.sh
{ printf '#!/usr/bin/env bash\nset -euo pipefail\n'; shared_block; printf 'report_status second skip idle\n'; } > second.sh
{ printf '#!/usr/bin/env bash\nset -euo pipefail\n'; unique_lines 120; } > filler.sh
chmod +x first.sh second.sh filler.sh
git add -A
git commit -qm 'chore: initialize' || fail "fixture commit failed"

out=$(substrate-engine gate --update-baseline 2>&1) || fail "initial baseline failed: $out"
ceiling=$(jq -r '.metrics.dup_pct' substrate-baseline.json)
awk -v c="$ceiling" 'BEGIN { exit !(c > 0) }' || fail "fixture carries no duplication (dup_pct=$ceiling), the scenario would be vacuous"
baseline_sum=$(sha256sum substrate-baseline.json)

{ printf '#!/usr/bin/env bash\nset -euo pipefail\n'; unique_lines 60; } > filler.sh
if out=$(substrate-engine gate 2>&1); then
    fail "deleting unrelated lines did not move dup_pct past its ceiling, the scenario would be vacuous: $out"
fi
shrunk=$(sed -n 's/^dup_pct: \([0-9.]*\) (best .*/\1/p' <<< "$out")
[ -n "$shrunk" ] || fail "the exact ratchet did not name dup_pct: $out"

slack=$(awk -v c="$ceiling" -v s="$shrunk" 'BEGIN { printf "%.6f", (s - c) * 1.5 }')
if ! jq --argjson slack "$slack" '.ratchet.tolerance = {dup_pct: $slack}' substrate.json > substrate.json.tmp; then
    fail "tolerance seed failed"
fi
mv substrate.json.tmp substrate.json

out=$(substrate-engine gate 2>&1) || fail "a deletion inside ratchet.tolerance red the gate: $out"
grep -Fq "dup_pct: $shrunk (best $ceiling, tolerance " <<< "$out" \
    || fail "the tolerated drift was not reported: $out"

out=$(substrate-engine gate --tighten 2>&1) || fail "tightening inside ratchet.tolerance failed: $out"
[ "$baseline_sum" = "$(sha256sum substrate-baseline.json)" ] \
    || fail "tightening moved a ceiling that was only inside its tolerance"

{ printf '#!/usr/bin/env bash\nset -euo pipefail\n'; shared_block; printf 'report_status third ok ready\n'; } > third.sh
chmod +x third.sh
git add third.sh
if out=$(substrate-engine gate 2>&1); then
    fail "a new clone beyond ratchet.tolerance passed the gate: $out"
fi
grep -q "^dup_pct: .* (best $ceiling)$" <<< "$out" || fail "the regression beyond tolerance lost its ratchet line: $out"

printf 'ratchet-tolerance-test: deletion inside tolerance green, ceiling held, new clone red\n'
