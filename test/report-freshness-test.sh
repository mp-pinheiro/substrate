#!/usr/bin/env bash
# Local cadence oracle: a missing or stale substrate-report.md must fail the
# gate with a actionable message, report --write must produce the artifact
# the check accepts, and report.max_age_days: 0 must opt out cleanly.
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# scratch inits must never touch the live user harness (~/.claude, ~/.omp)
export SUBSTRATE_NO_USER_HARNESS=1

fail() { printf 'report-freshness-test FAIL: %s\n' "$1" >&2; exit 1; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
cd "$T" || exit 9
git init -q .
git config user.email substrate@localhost
git config user.name substrate
printf '#!/usr/bin/env bash\nls "$@"\n' > x.sh
chmod +x x.sh
env -u CI "$KIT_ROOT/bin/substrate" init --profile shell >/dev/null 2>&1 || fail "init failed"
git add -A
git commit -qm 'feat: seed'

out=$(env -u CI .substrate/gate.sh 2>&1)
rc=$?
[ "$rc" -ne 0 ] || fail "gate green without a maintenance report"
grep -q 'no maintenance report — run: substrate report --write' <<< "$out" \
    || fail "missing-report finding not named: $out"

.substrate/report.sh --write >/dev/null 2>&1 || fail "report --write failed"
[ -f substrate-report.md ] || fail "substrate-report.md not written"
head -n1 substrate-report.md | grep -qE '^generated: [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$' \
    || fail "generated header malformed: $(head -n1 substrate-report.md)"

out=$(env -u CI .substrate/gate.sh --update-baseline 2>&1) \
    || fail "gate not green with fresh report: $out"

old=$(date -u -d '30 days ago' +%Y-%m-%dT%H:%M:%SZ)
{ printf 'generated: %s\n' "$old"; tail -n +2 substrate-report.md; } > r.tmp && mv r.tmp substrate-report.md
out=$(env -u CI .substrate/gate.sh 2>&1)
rc=$?
[ "$rc" -ne 0 ] || fail "gate green with a 30-day-old report"
grep -q 'days old (max 14)' <<< "$out" || fail "staleness not named: $out"

jq '.report.max_age_days = 0' substrate.json > s.tmp && mv s.tmp substrate.json
out=$(env -u CI .substrate/gate.sh 2>&1) || fail "max_age_days: 0 opt-out not honored: $out"

printf 'report-freshness-test: missing, fresh, stale, opt-out green\n'
