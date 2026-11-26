#!/usr/bin/env bash
set -uo pipefail

if [ -n "${BATTERY_PATH_PROBE:-}" ]; then
    { command -v substrate-engine || echo; command -v battery-path-tool || echo; } > "$BATTERY_PATH_PROBE"
    exit 0
fi

fail() { printf 'battery-path-test FAIL: %s\n' "$1" >&2; exit 1; }

cd "$(dirname "${BASH_SOURCE[0]}")/.." || fail "kit root"
T=$(mktemp -d) || fail "scratch dir"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/ahead" "$T/installed" || fail "scratch layout"
for stub in "$T/installed/gitleaks" "$T/installed/substrate-engine" "$T/installed/battery-path-tool" "$T/ahead/battery-path-tool"; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$stub"
    chmod +x "$stub"
done

PATH="$T/ahead:$T/installed:$PATH" BATTERY_PATH_PROBE="$T/resolved" \
    bash test/run.sh --only battery-path-test > "$T/run.out" 2>&1 \
    || fail "the probe run failed: $(cat "$T/run.out")"
mapfile -t resolved < "$T/resolved"
[ "${resolved[0]:-}" -ef build/substrate-engine ] \
    || fail "suites resolved substrate-engine to '${resolved[0]:-}' with another engine installed beside gitleaks"
[ "${resolved[1]:-}" = "$T/ahead/battery-path-tool" ] \
    || fail "suites resolved a tool to '${resolved[1]:-}', behind the gitleaks directory that follows it on PATH"

printf 'battery-path-test: suites resolve the checkout engine and keep PATH order around a gitleaks directory\n'
