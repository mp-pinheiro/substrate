#!/usr/bin/env bash
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/scratch-repo-fixture.sh
source "$KIT_ROOT/test/lib/scratch-repo-fixture.sh"

fail() { printf 'baseline-test FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { printf '\033[0;32m[ok]\033[0m baseline-test: %s\n' "$*"; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export HOME="$T/home" SUBSTRATE_NO_USER_HARNESS=1
mkdir -p "$HOME" "$T/fake-bin"

scratch_repo_init "$T/repo" base || fail "init failed"
cd "$T/repo" || exit 9
printf 'safe\n' > tracked.txt
cat > .substrate/checks.d/58-baseline-probe.sh <<'SH'
#!/usr/bin/env bash
set -uo pipefail
source "$SUBSTRATE_DIR/gate-lib.sh"
while IFS=$'\t' read -r name value; do
    case "$name" in
        hi:*|probe_hi) metric_hi "$name" "$value" ;;
        *) metric "$name" "$value" ;;
    esac
done < <(jq -r 'to_entries[] | [.key, .value] | @tsv' "$REPO_ROOT/.git/probe-metrics.json")
SH
chmod +x .substrate/checks.d/58-baseline-probe.sh
cat > "$T/fake-bin/gitleaks" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
    version) printf 'baseline-fake-v1\n' ;;
    git) exit 0 ;;
    *) exit 2 ;;
esac
SH
chmod +x "$T/fake-bin/gitleaks"
export PATH="$T/fake-bin:$PATH"

printf '{"probe:alpha":10,"probe:beta":20}\n' > .git/probe-metrics.json
git add -A
git commit -qm 'chore: initialize' || fail "fixture commit failed"
if ! out=$(substrate-engine gate --update-baseline 2>&1); then
    fail "initial baseline creation failed: $out"
fi
jq -e '.metrics["probe:alpha"] == 10 and .metrics["probe:beta"] == 20' \
    substrate-baseline.json >/dev/null || fail "initial baseline values are wrong"

printf '{"probe:alpha":5,"probe:beta":20}\n' > .git/probe-metrics.json
substrate-engine gate --tighten >/dev/null 2>&1 || fail "monotonic tightening failed"
jq -e '.metrics["probe:alpha"] == 5 and .metrics["probe:beta"] == 20' \
    substrate-baseline.json >/dev/null || fail "tightening did not lower only the improved metric"

printf '{"probe:alpha":4,"probe:beta":30}\n' > .git/probe-metrics.json
before=$(sha256sum substrate-baseline.json)
if substrate-engine gate --tighten > "$T/regression.out" 2>&1; then
    fail "tightening accepted a regression"
fi
[ "$before" = "$(sha256sum substrate-baseline.json)" ] \
    || fail "failed tightening partially changed the baseline"

if ! out=$(substrate-engine gate --tighten --accept-regression=probe:beta --reason='probe beta metric regressed because the probe fixture grew intentionally' 2>&1); then
    fail "keyed accept-regression on a namespaced metric failed: $out"
fi
jq -e '.metrics["probe:beta"] == 30' substrate-baseline.json >/dev/null \
    || fail "keyed accept-regression did not persist the new floor for a namespaced metric"

if ! substrate-engine gate --update-baseline --accept-regression --reason='both probe metrics regressed because the probe fixture grew intentionally' > "$T/accept.out" 2>&1; then
    fail "explicit regression acceptance failed: $(cat "$T/accept.out")"
fi
grep -Fq 'accepting regressions' "$T/accept.out" || fail "explicit loosening did not print its diff"
jq -e '.metrics["probe:alpha"] == 4 and .metrics["probe:beta"] == 30' \
    substrate-baseline.json >/dev/null || fail "explicit loosening did not record current values"

printf '{"probe:alpha":3,"probe:gamma":0}\n' > .git/probe-metrics.json
chmod 444 substrate-baseline.json
if ! out=$(substrate-engine gate --tighten 2>&1); then
    fail "tightening with a locked baseline failed: $out"
fi
[ "$(stat -c '%a' substrate-baseline.json)" = 444 ] || fail "atomic replacement changed baseline mode"
jq -e '.metrics["probe:alpha"] == 3 and (.metrics | has("probe:beta") | not) and .metrics["probe:gamma"] == 0' \
    substrate-baseline.json >/dev/null \
    || fail "tightening kept a lower-is-better orphan or missed a zero-tolerance metric"
grep -Fq 'pruning resolved ceiling(s): probe:beta' <<< "$out" \
    || fail "orphan prune was silent — a vanished check must not pass unreported"

printf '{"probe:alpha":3,"hi:cov":90}\n' > .git/probe-metrics.json
substrate-engine gate --tighten >/dev/null 2>&1 || fail "recording a higher-is-better metric failed"
jq -e '.metrics["hi:cov"] == 90 and .direction["hi:cov"] == "hi"' substrate-baseline.json >/dev/null \
    || fail "higher-is-better metric was not recorded with its direction"
printf '{"probe:alpha":3}\n' > .git/probe-metrics.json
substrate-engine gate --tighten >/dev/null 2>&1 || fail "tightening with an idle hi metric failed"
jq -e '.metrics["hi:cov"] == 90 and .direction["hi:cov"] == "hi"' substrate-baseline.json >/dev/null \
    || fail "higher-is-better orphan lost its floor or direction — absence there means no floor, not zero tolerance"

printf '{"probe:alpha":2,"probe:gamma":0}\n' > .git/probe-metrics.json
before=$(sha256sum substrate-baseline.json)
if [ "$(id -u)" -ne 0 ]; then
    chmod a-w "$PWD"
    if substrate-engine gate --tighten > "$T/atomic.out" 2>&1; then
        fail "baseline write succeeded with read-only parent directory"
    fi
    grep -Fq 'not writing' "$T/atomic.out" || fail "atomic write failure was not actionable"
    [ "$before" = "$(sha256sum substrate-baseline.json)" ] || fail "atomic write failure changed the original baseline"
    chmod u+w "$PWD"
else
    ok "read-only parent directory check skipped (running as root, DAC bypassed)"
fi

printf 'baseline-test: monotonic, explicit loosening, reported orphan prune, hi-floor retention, atomic rollback green\n'

# --- accepted-record assertions --- gate:allow-comment
# Establish probe:beta in the baseline first (it was pruned in step 6)
jq '.metrics["probe:beta"] = 20' substrate-baseline.json > substrate-baseline.json.tmp \
    && mv substrate-baseline.json.tmp substrate-baseline.json \
    || fail "seeding probe:beta into baseline failed"
jq -e '.metrics["probe:beta"] == 20' substrate-baseline.json >/dev/null || fail "probe:beta not in baseline after seed"

# Accept regression: 20 -> 60
printf '{"probe:alpha":3,"probe:beta":60}\n' > .git/probe-metrics.json
if ! substrate-engine gate --tighten --accept-regression=probe:beta --reason='first accept probe beta regression sixty characters' 2>&1; then
    fail "first accept of probe:beta failed"
fi
jq -e '.accepted["probe:beta"] | .from == 20 and .to == 60 and .reason == "first accept probe beta regression sixty characters" and (.at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))' \
    substrate-baseline.json >/dev/null || fail "accepted record missing or malformed for probe:beta"

# idempotent: re-accept with same metrics
sha_before=$(sha256sum substrate-baseline.json)
substrate-engine gate --tighten --accept-regression=probe:beta --reason='first accept probe beta regression sixty characters' >/dev/null 2>&1 \
    || fail "idempotent accept of probe:beta failed"
[ "$sha_before" = "$(sha256sum substrate-baseline.json)" ] \
    || fail "idempotent accept re-stamped the baseline — at timestamp must not refresh"

# auto-prune: return probe:beta to its from value (20)
printf '{"probe:alpha":3,"probe:beta":20}\n' > .git/probe-metrics.json
substrate-engine gate --tighten >/dev/null 2>&1 || fail "tightening probe:beta back to from failed"
jq -e '.accepted | has("probe:beta") | not' substrate-baseline.json >/dev/null \
    || fail "auto-prune failed — probe:beta record should disappear when metric returns to from"

# sticky from: accept 20 -> 30
printf '{"probe:alpha":3,"probe:beta":30}\n' > .git/probe-metrics.json
substrate-engine gate --tighten --accept-regression=probe:beta --reason='first sticky accept twenty characters now' 2>&1 || fail "first sticky accept failed"
jq -e '.accepted["probe:beta"] | .from == 20 and .to == 30' substrate-baseline.json >/dev/null \
    || fail "first sticky accept from wrong — accepted: $(jq -c .accepted substrate-baseline.json)"
# then 30 -> 40 gate:allow-comment
printf '{"probe:alpha":3,"probe:beta":40}\n' > .git/probe-metrics.json
substrate-engine gate --tighten --accept-regression=probe:beta --reason='second sticky accept twenty characters ok' 2>&1 || fail "second sticky accept failed"
jq -e '.accepted["probe:beta"] | .from == 20 and .to == 40' substrate-baseline.json >/dev/null \
    || fail "sticky from failed — accepted: $(jq -c .accepted substrate-baseline.json)"

# partial payback: to field updates to current ceiling on tighten
printf '{"probe:alpha":3,"probe:beta":35}\n' > .git/probe-metrics.json
substrate-engine gate --tighten >/dev/null 2>&1 || fail "partial payback tighten failed"
jq -e '.accepted["probe:beta"] | .from == 20 and .to == 35' substrate-baseline.json >/dev/null \
    || fail "to field stale after partial payback — accepted: $(jq -c .accepted substrate-baseline.json)"

# refusals: various invalid --reason forms
printf '{"probe:alpha":3,"probe:beta":50}\n' > .git/probe-metrics.json
if substrate-engine gate --tighten --accept-regression=probe:beta >/dev/null 2>&1; then fail "accepted without --reason"; fi
if substrate-engine gate --tighten --accept-regression=probe:beta --reason='short' >/dev/null 2>&1; then fail "accepted with short reason"; fi
if substrate-engine gate --tighten --accept-regression=probe:beta --reason='this reason has a > in it which is forbidden' >/dev/null 2>&1; then fail "accepted reason with >"; fi
if substrate-engine gate --tighten --reason='this reason is perfectly valid but no accept flag' >/dev/null 2>&1; then fail "reason without accept-regression"; fi

# never-accept: add policy and try to accept
jq '. + {"ratchet": {"never_accept": ["probe:alpha"]}}' substrate.json > substrate.json.tmp && mv substrate.json.tmp substrate.json
printf '{"probe:alpha":15,"probe:beta":50}\n' > .git/probe-metrics.json
if substrate-engine gate --tighten --accept-regression=probe:alpha --reason='trying to accept a never acceptable metric twenty' > "$T/never.out" 2>&1; then
    fail "accepted a never-acceptable metric"
fi
grep -q 'never-acceptable' "$T/never.out" || fail "never-acceptable rejection was not stated"
printf '{"probe:alpha":3,"probe:beta":35}\n' > .git/probe-metrics.json

printf '# budget-test: 749\n' > budget.yaml
seq 748 >> budget.yaml
git add budget.yaml
substrate-engine gate --tighten > "$T/budget-749.out" 2>&1 || fail "749-line budget unexpectedly failed: $(cat "$T/budget-749.out")"
printf '# budget-test: 750\n' > budget.yaml
seq 749 >> budget.yaml
substrate-engine gate --tighten > "$T/budget-750.out" 2>&1 || fail "750-line budget unexpectedly failed: $(cat "$T/budget-750.out")"
printf '# budget-test: 751\n' > budget.yaml
seq 750 >> budget.yaml
if substrate-engine gate --tighten > "$T/headroom.out" 2>&1; then
    fail "751-line budget unexpectedly passed"
fi
grep -q 'hard cap' "$T/headroom.out" || fail "hard cap not displayed for over-cap metric"
grep -q 'budget.yaml' "$T/headroom.out" || fail "over-cap culprit path missing"

before=$(sha256sum substrate-baseline.json)
if substrate-engine gate --tighten --accept-regression=max_file_lines --reason='hard budget requires a refactor instead of ratchet acceptance' --json > "$T/budget-accept.out" 2>&1; then
    fail "max_file_lines regression acceptance was allowed"
fi
jq -e '.code == "gate.budget-acceptance" and .owner == "user" and .retry == "terminal"' "$T/budget-accept.out" >/dev/null \
    || fail "max_file_lines acceptance did not emit terminal user report"
[ "$before" = "$(sha256sum substrate-baseline.json)" ] || fail "budget acceptance changed baseline bytes"

jq '.metrics.max_file_lines = 749 | .direction.max_file_lines = "lo" | .accepted.max_file_lines = {"from": 1, "to": 2}' substrate-baseline.json > substrate-baseline.json.tmp \
    && mv substrate-baseline.json.tmp substrate-baseline.json \
    || fail "legacy max_file_lines baseline seed failed"
printf '# budget-test: green\n' > budget.yaml
seq 748 >> budget.yaml
substrate-engine gate --tighten >/dev/null 2>&1 || fail "green budget migration failed"
jq -e '(.metrics | has("max_file_lines") | not) and (.direction | has("max_file_lines") | not) and (.accepted | has("max_file_lines") | not)' substrate-baseline.json >/dev/null \
    || fail "legacy max_file_lines baseline keys were not pruned"

printf 'baseline-test: hard max_file_lines budget and migration green\n'
ok "hard budget boundary, rejection, and legacy migration"
