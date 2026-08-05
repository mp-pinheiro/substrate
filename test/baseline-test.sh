#!/usr/bin/env bash
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"
export SUBSTRATE_NO_USER_HARNESS=1
mkdir -p "$HOME" "$T/repo" "$T/fake-bin"

fail() { printf 'baseline-test FAIL: %s\n' "$1" >&2; exit 1; }

cd "$T/repo" || exit 9
git init -q --initial-branch=main
git config user.name substrate
git config user.email substrate@localhost
printf 'safe\n' > tracked.txt
"$KIT_ROOT/bin/substrate" init --profile base --vcs git >/dev/null 2>&1 || fail "init failed"
cat > .substrate/checks.d/58-baseline-probe.sh <<'SH'
#!/usr/bin/env bash
set -uo pipefail
source "$SUBSTRATE_DIR/gate-lib.sh"
while IFS=$'\t' read -r name value; do
    case "$name" in
        hi:*) metric_hi "$name" "$value" ;;
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
if ! out=$(.substrate/gate.sh --update-baseline 2>&1); then
    fail "initial baseline creation failed: $out"
fi
jq -e '.metrics["probe:alpha"] == 10 and .metrics["probe:beta"] == 20' \
    substrate-baseline.json >/dev/null || fail "initial baseline values are wrong"

printf '{"probe:alpha":5,"probe:beta":20}\n' > .git/probe-metrics.json
.substrate/gate.sh --tighten >/dev/null 2>&1 || fail "monotonic tightening failed"
jq -e '.metrics["probe:alpha"] == 5 and .metrics["probe:beta"] == 20' \
    substrate-baseline.json >/dev/null || fail "tightening did not lower only the improved metric"

printf '{"probe:alpha":4,"probe:beta":30}\n' > .git/probe-metrics.json
before=$(sha256sum substrate-baseline.json)
if .substrate/gate.sh --tighten > "$T/regression.out" 2>&1; then
    fail "tightening accepted a regression"
fi
[ "$before" = "$(sha256sum substrate-baseline.json)" ] \
    || fail "failed tightening partially changed the baseline"

if ! .substrate/gate.sh --update-baseline --accept-regression > "$T/accept.out" 2>&1; then
    fail "explicit regression acceptance failed: $(cat "$T/accept.out")"
fi
grep -Fq 'accepting regressions' "$T/accept.out" || fail "explicit loosening did not print its diff"
jq -e '.metrics["probe:alpha"] == 4 and .metrics["probe:beta"] == 30' \
    substrate-baseline.json >/dev/null || fail "explicit loosening did not record current values"

printf '{"probe:alpha":3,"probe:gamma":0}\n' > .git/probe-metrics.json
chmod 444 substrate-baseline.json
if ! out=$(.substrate/gate.sh --tighten 2>&1); then
    fail "tightening with a locked baseline failed: $out"
fi
[ "$(stat -c '%a' substrate-baseline.json)" = 444 ] || fail "atomic replacement changed baseline mode"
jq -e '.metrics["probe:alpha"] == 3 and (.metrics | has("probe:beta") | not) and .metrics["probe:gamma"] == 0' \
    substrate-baseline.json >/dev/null \
    || fail "tightening kept a lower-is-better orphan or missed a zero-tolerance metric"
grep -Fq 'pruning resolved ceiling(s): probe:beta' <<< "$out" \
    || fail "orphan prune was silent — a vanished check must not pass unreported"

printf '{"probe:alpha":3,"hi:cov":90}\n' > .git/probe-metrics.json
.substrate/gate.sh --tighten >/dev/null 2>&1 || fail "recording a higher-is-better metric failed"
jq -e '.metrics["hi:cov"] == 90 and .direction["hi:cov"] == "hi"' substrate-baseline.json >/dev/null \
    || fail "higher-is-better metric was not recorded with its direction"
printf '{"probe:alpha":3}\n' > .git/probe-metrics.json
.substrate/gate.sh --tighten >/dev/null 2>&1 || fail "tightening with an idle hi metric failed"
jq -e '.metrics["hi:cov"] == 90 and .direction["hi:cov"] == "hi"' substrate-baseline.json >/dev/null \
    || fail "higher-is-better orphan lost its floor or direction — absence there means no floor, not zero tolerance"

printf '{"probe:alpha":2,"probe:gamma":0}\n' > .git/probe-metrics.json
before=$(sha256sum substrate-baseline.json)
cat > "$T/fake-bin/mv" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
    case "$arg" in
        */substrate-baseline.json) exit 42 ;;
    esac
done
exec /usr/bin/mv "$@"
SH
chmod +x "$T/fake-bin/mv"
if .substrate/gate.sh --tighten > "$T/atomic.out" 2>&1; then
    fail "baseline write succeeded after atomic replacement failure"
fi
grep -Fq 'atomic replacement failed' "$T/atomic.out" || fail "atomic write failure was not actionable"
[ "$before" = "$(sha256sum substrate-baseline.json)" ] || fail "atomic write failure changed the original baseline"

printf 'baseline-test: monotonic, explicit loosening, reported orphan prune, hi-floor retention, atomic rollback green\n'
