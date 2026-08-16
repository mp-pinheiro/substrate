#!/usr/bin/env bash
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/engine-fixture.sh
source "$KIT_ROOT/test/lib/engine-fixture.sh"
engine_fixture_home
export SUBSTRATE_NO_USER_HARNESS=1

fail() { printf 'doctor-attestation-test FAIL: %s\n' "$1" >&2; exit 1; }

command -v go >/dev/null 2>&1 || fail "go is required for the doctor attestation oracle"
KIT_VERSION=$(cat "$KIT_ROOT/VERSION")

STAMPED_BIN=$(engine_build fail stamped "$KIT_VERSION") || exit 1
STAMPED_SHA=$(sha256sum "$STAMPED_BIN" | cut -d ' ' -f 1)

DEV_BIN=$(engine_build fail dev) || exit 1
DEV_VERSION=$("$DEV_BIN" version)
case "$DEV_VERSION" in
    0.0.0-*) ;;
    *) fail "an unstamped build did not default to a 0.0.0-* dev version (got $DEV_VERSION)" ;;
esac

WRONG_SHA="${STAMPED_SHA%?}0"
[ "$WRONG_SHA" != "$STAMPED_SHA" ] || WRONG_SHA="${STAMPED_SHA%?}1"

FIXTURE_BIN_STAMPED="$T/fixture-bin-stamped"
mkdir -p "$FIXTURE_BIN_STAMPED"
cp "$STAMPED_BIN" "$FIXTURE_BIN_STAMPED/substrate-engine"
chmod +x "$FIXTURE_BIN_STAMPED/substrate-engine"

FIXTURE_BIN_DEV="$T/fixture-bin-dev"
mkdir -p "$FIXTURE_BIN_DEV"
cp "$DEV_BIN" "$FIXTURE_BIN_DEV/substrate-engine"
chmod +x "$FIXTURE_BIN_DEV/substrate-engine"

BASE_PATH=""
IFS=: read -r -a base_path_parts <<< "$PATH"
for base_path_dir in "${base_path_parts[@]}"; do
    [ "$base_path_dir" = "$KIT_ROOT/build" ] && continue
    BASE_PATH="${BASE_PATH:+$BASE_PATH:}$base_path_dir"
done

REPO="$T/repo"
mkdir -p "$REPO"
cd "$REPO" || exit 9
git init -q --initial-branch=main
git config user.name substrate
git config user.email substrate@localhost
printf 'tracked\n' > tracked.txt
git add tracked.txt
git commit -qm 'chore: initialize'
"$KIT_ROOT/bin/substrate" init --profile base --vcs git >/dev/null 2>&1 || fail "fixture init failed"

strip_ansi() {
    local s="$1"
    s="${s//$'\033[0;34m'/}"
    s="${s//$'\033[0;32m'/}"
    s="${s//$'\033[0;33m'/}"
    s="${s//$'\033[0m'/}"
    printf '%s\n' "$s"
}

doctor_out() {
    (cd "$REPO" && env "$@" "$KIT_ROOT/bin/substrate" doctor 2>&1)
}

expect_line() {
    local label="$1" clean="$2" want="$3"
    grep -Fxq "$want" <<< "$clean" || fail "$label: missing exact line: $want"
}

write_pin() {
    printf '{"version":"%s","binary_sha256":"%s"}\n' "$1" "$2" > "$REPO/.substrate/engine.json"
}

assert_doctor_pin() {
    local label="$1" expected_rc="$2" expected_line="$3"
    shift 3
    local out rc clean
    out=$(doctor_out "$@")
    rc=$?
    clean=$(strip_ansi "$out")
    [ "$rc" -eq "$expected_rc" ] || fail "$label: expected exit $expected_rc, got $rc"
    expect_line "$label" "$clean" "$expected_line"
}

rm -f "$REPO/.substrate/engine.json"
assert_doctor_pin "pin missing" 0 \
    "[!] engine pin: .substrate/engine.json missing — run: substrate update --apply" \
    PATH="$BASE_PATH"

write_pin "$KIT_VERSION" "$STAMPED_SHA"
assert_doctor_pin "attested" 0 \
    "[ok] engine pin: $KIT_VERSION attested (sha256 ${STAMPED_SHA:0:12})" \
    PATH="$FIXTURE_BIN_STAMPED:$BASE_PATH" SUBSTRATE_ENGINE_BIN=

write_pin "$KIT_VERSION" "$STAMPED_SHA"
assert_doctor_pin "no local engine" 0 \
    "[ok] engine pin: $KIT_VERSION pinned (sha256 ${STAMPED_SHA:0:12}) — no local engine to attest" \
    PATH="$BASE_PATH" SUBSTRATE_ENGINE_BIN=

write_pin "$KIT_VERSION" "$STAMPED_SHA"
assert_doctor_pin "dev build" 0 \
    "[!] engine pin: dev build $DEV_VERSION not attested — build with: just engine (stamped)" \
    PATH="$FIXTURE_BIN_DEV:$BASE_PATH" SUBSTRATE_ENGINE_BIN=

write_pin "$KIT_VERSION" "$STAMPED_SHA"
assert_doctor_pin "override" 0 \
    "[!] engine pin: SUBSTRATE_ENGINE_BIN override not attested — pin covers the vendored install only" \
    PATH="$BASE_PATH" SUBSTRATE_ENGINE_BIN="$STAMPED_BIN"

write_pin "$KIT_VERSION" "$WRONG_SHA"
assert_doctor_pin "mismatch" 2 \
    "[!] engine pin: $FIXTURE_BIN_STAMPED/substrate-engine sha256 ${STAMPED_SHA:0:12} does not match .substrate/engine.json (${WRONG_SHA:0:12})" \
    PATH="$FIXTURE_BIN_STAMPED:$BASE_PATH" SUBSTRATE_ENGINE_BIN=

printf 'doctor-attestation-test: pin missing, attested, no-engine, dev-build, override, mismatch all green\n'
