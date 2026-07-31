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

printf 'audit-test: 3 cases green\n'
