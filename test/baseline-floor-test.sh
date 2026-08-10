#!/usr/bin/env bash
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/scratch-repo-fixture.sh
source "$KIT_ROOT/test/lib/scratch-repo-fixture.sh"

fail() { printf 'baseline-floor-test FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { printf '\033[0;32m[ok]\033[0m baseline-floor-test: %s\n' "$*"; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export HOME="$T/home" SUBSTRATE_NO_USER_HARNESS=1
mkdir -p "$HOME"
scratch_repo_init "$T/repo" base || fail "init failed"
cd "$T/repo" || exit 9
printf 'safe\n' > tracked.txt

cat > .substrate/checks.d/58-baseline-probe.sh <<'SH'
#!/usr/bin/env bash
set -uo pipefail
source "$SUBSTRATE_DIR/gate-lib.sh"
while IFS=$'\t' read -r name value; do
    case "$name" in
        probe_hi:*) metric_hi "$name" "$value" ;;
        *) metric "$name" "$value" ;;
    esac
done < <(jq -r 'to_entries[] | [.key, .value] | @tsv' "$REPO_ROOT/.git/probe-metrics.json")
SH
chmod +x .substrate/checks.d/58-baseline-probe.sh

git add -A
git commit -qm 'feat: probe check'

printf '{"probe_hi:cov":10,"probe_lo:count":5}\n' > .git/probe-metrics.json
if ! substrate-engine gate --update-baseline >/dev/null 2>&1; then
    fail "initial baseline creation failed"
fi
jq -e '.metrics["probe_hi:cov"] == 10 and .direction["probe_hi:cov"] == "hi"' substrate-baseline.json >/dev/null \
    || fail "probe_hi:cov not recorded with hi direction"

printf '{"probe_lo:count":3}\n' > .git/probe-metrics.json
if ! substrate-engine gate --update-baseline >/dev/null 2>&1; then
    fail "bare update-baseline with unemitted hi metric failed"
fi
jq -e '.metrics["probe_hi:cov"] == 10 and .direction["probe_hi:cov"] == "hi"' substrate-baseline.json >/dev/null \
    || fail "probe_hi:cov lost its floor or direction when not emitted"
jq -e '.metrics["probe_lo:count"] == 3' substrate-baseline.json >/dev/null \
    || fail "probe_lo:count not tightened"

ok "bare update-baseline preserves unemitted hi-floors"
