#!/usr/bin/env bash
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fail() {
    printf 'release-wait-gate-test: %s\n' "$1" >&2
    exit 1
}

cat > "$WORK/forge" <<'SH'
#!/usr/bin/env bash
IFS=' ' read -r -a statuses <<< "${FAKE_STATUSES:-}"
index=0
[ ! -f "$FAKE_STATE" ] || index=$(cat "$FAKE_STATE")
if [ "$index" -ge "${#statuses[@]}" ]; then
    index=$((${#statuses[@]} - 1))
fi
printf '%s\n' "${statuses[$index]:-}"
printf '%s\n' "$((index + 1))" > "$FAKE_STATE"
SH
chmod +x "$WORK/forge"

run_wait() {
    local event="$1" statuses="$2" attempts="$3" output="$4" state="$5"
    rm -f "$output" "$state"
    env RELEASE_FORGE_BIN="$WORK/forge" RELEASE_HEAD_SHA=abc123 RELEASE_EVENT="$event" \
        RELEASE_GATE_ATTEMPTS="$attempts" RELEASE_GATE_DELAY=0 RELEASE_OUTPUT="$output" \
        FAKE_STATUSES="$statuses" FAKE_STATE="$state" \
        "$KIT_ROOT/core/release-wait-gate.sh"
}

run_wait push "pending success" 3 "$WORK/success.out" "$WORK/success.state" \
    || fail "pending gate did not resolve to success"
grep -qx 'status=success' "$WORK/success.out" || fail "success output missing"
[ "$(cat "$WORK/success.state")" = 2 ] || fail "success path did not wait exactly once"

run_wait push "failure" 1 "$WORK/failure.out" "$WORK/failure.state" > "$WORK/failure.log" 2>&1 \
    && fail "failed gate allowed release"
grep -q 'gate failed for abc123' "$WORK/failure.log" || fail "failure did not name the revision"

run_wait schedule "pending" 1 "$WORK/schedule.out" "$WORK/schedule.state" > "$WORK/schedule.log" 2>&1 \
    || fail "scheduled release did not skip a pending gate"
grep -qx 'status=pending' "$WORK/schedule.out" || fail "scheduled skip did not expose pending status"
grep -q 'nothing to publish tonight' "$WORK/schedule.log" || fail "scheduled skip was not announced"

run_wait workflow_dispatch "pending" 1 "$WORK/timeout.out" "$WORK/timeout.state" > "$WORK/timeout.log" 2>&1 \
    && fail "manual release accepted a gate timeout"
grep -q 'refusing release' "$WORK/timeout.log" || fail "manual timeout did not fail closed"

printf 'release-wait-gate-test: pending, success, failure, schedule, and timeout scenarios green\n'
