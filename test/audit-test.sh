#!/usr/bin/env bash
# Negative battery for the audit runner: a checked claim whose verify command
# fails must fail the audit; a committed plan with any failing item must fail;
# an active plan with pending items must not.
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/.pi/plans" "$T/.substrate"
cp "$KIT_ROOT/core/audit.sh" "$T/.substrate/audit.sh"
chmod +x "$T/.substrate/audit.sh"

fail() { printf 'audit-test FAIL: %s\n' "$1" >&2; exit 1; }

cat > "$T/.pi/plans/regressed.md" <<'EOF'
# Plan: regression case
state: active
## Acceptance
- [x] locked claim that broke :: false
EOF
"$T/.substrate/audit.sh" >/dev/null 2>&1 && fail "regressed [x] claim did not fail the audit"
rm "$T/.pi/plans/regressed.md"

cat > "$T/.pi/plans/committed.md" <<'EOF'
# Plan: committed case
state: committed
## Acceptance
- [x] holds :: true
- [x] broke :: false
EOF
"$T/.substrate/audit.sh" >/dev/null 2>&1 && fail "committed plan with failing item did not fail the audit"
rm "$T/.pi/plans/committed.md"

cat > "$T/.pi/plans/pending.md" <<'EOF'
# Plan: pending case
state: active
## Acceptance
- [x] holds :: true
- [ ] open work :: false
EOF
"$T/.substrate/audit.sh" >/dev/null 2>&1 || fail "active plan with pending item wrongly failed the audit"
rm "$T/.pi/plans/pending.md"

cat > "$T/.pi/plans/offline.md" <<'EOF'
# Plan: unverifiable case
state: committed
## Acceptance
- [x] local thing :: true
- [x] remote thing :: exit 3
EOF
out=$("$T/.substrate/audit.sh" 2>&1)
rc=$?
[ "$rc" -eq 0 ] || fail "unverifiable oracle failed the audit (rc=$rc): $out"
grep -q '\[--\] remote thing — UNVERIFIABLE' <<< "$out" || fail "unverifiable item not marked [--]: $out"
grep -q '1 unverifiable' <<< "$out" || fail "unverifiable count missing from summary: $out"
rm "$T/.pi/plans/offline.md"

cat > "$T/.pi/plans/mixed.md" <<'EOF'
# Plan: unverifiable does not mask regression
state: committed
## Acceptance
- [x] remote thing :: exit 3
- [x] broke :: false
EOF
"$T/.substrate/audit.sh" >/dev/null 2>&1 && fail "regression masked by unverifiable sibling"

printf 'audit-test: 5 cases green\n'
