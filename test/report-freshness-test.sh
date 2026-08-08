#!/usr/bin/env bash
# Local maintenance is session-driven advisory state and never a gate input.
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

[ ! -e substrate-report.md ] || fail "init unexpectedly wrote advisory state"
out=$(env -u CI .substrate/gate.sh --update-baseline 2>&1) \
    || fail "missing report blocked the gate: $out"
[ ! -e .substrate/checks.d/55-report-freshness.sh ] \
    || fail "blocking freshness check is still vendored"

printf '{"session_id":"report-one"}\n' | .substrate/hooks/agent-lifecycle.sh start >/dev/null \
    || fail "session-start refresh failed"
[ -f substrate-report.md ] || fail "session start did not write the report"
grep -qE '^generated: [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$' substrate-report.md \
    || fail "generated header malformed"
grep -q '^# Substrate maintenance report$' substrate-report.md || fail "report heading missing"
grep -q '^## Duplicate code$' substrate-report.md || fail "duplication heading missing"
grep -q '^## Possible dead code$' substrate-report.md || fail "dead-code heading missing"
grep -q '^## Baseline limits$' substrate-report.md || fail "baseline heading missing"
grep -q '^## Raised ceilings$' substrate-report.md || fail "raised-ceilings heading missing"
git check-ignore -q substrate-report.md || fail "local report is not ignored"
[ -z "$(git status --porcelain -- substrate-report.md)" ] || fail "report dirtied the working tree"

before=$(grep -c '^/substrate-report.md$' .git/info/exclude)
.substrate/report.sh --refresh >/dev/null 2>&1 || fail "idempotent refresh failed"
after=$(grep -c '^/substrate-report.md$' .git/info/exclude)
[ "$before" -eq 1 ] && [ "$after" -eq 1 ] || fail "refresh duplicated the ignore entry"

old=$(date -u -d '30 days ago' +%Y-%m-%dT%H:%M:%SZ)
{ printf 'generated: %s\n' "$old"; tail -n +2 substrate-report.md; } > r.tmp \
    && mv r.tmp substrate-report.md
printf '{"session_id":"report-two"}\n' | .substrate/hooks/agent-lifecycle.sh start >/dev/null \
    || fail "stale report refresh failed"
grep -q "^generated: $old$" substrate-report.md && fail "stale report was not refreshed"

printf 'malformed advisory state\n' > substrate-report.md
out=$(env -u CI .substrate/gate.sh 2>&1) || fail "malformed report blocked the gate: $out"

target="$T/report-target"
printf 'preserve\n' > "$target"
rm -f substrate-report.md
ln -s "$target" substrate-report.md
out=$(.substrate/report.sh --refresh 2>&1)
[ "$?" -eq 0 ] || fail "advisory symlink refusal returned failure"
grep -q 'is a symlink — not writing' <<< "$out" || fail "symlink refusal was not reported"
[ "$(cat "$target")" = preserve ] || fail "report refresh followed a symlink"
rm -f substrate-report.md

jq '.report.max_age_days = 0' substrate.json > s.tmp && mv s.tmp substrate.json
printf '{"session_id":"report-three"}\n' | .substrate/hooks/agent-lifecycle.sh start >/dev/null \
    || fail "disabled refresh failed"
[ ! -e substrate-report.md ] || fail "max_age_days: 0 did not disable local refresh"
out=$(env -u CI .substrate/gate.sh 2>&1) || fail "disabled advisory state blocked the gate: $out"

printf 'report-freshness-test: automatic, ignored, advisory, idempotent, symlink-safe\n'
