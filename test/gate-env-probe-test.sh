#!/usr/bin/env bash
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$TEST_DIR/lib"
KIT_ROOT="$(cd "$TEST_DIR/.." && pwd)"
export KIT_ROOT

source "$LIB_DIR/engine-fixture.sh"
source "$LIB_DIR/scratch-repo-fixture.sh"

TMPDIR="${TMPDIR:-/tmp}"
WORK=$(mktemp -d "$TMPDIR/gate-env-probe.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

fail_fn() {
    printf '  [XX] %s\n' "$1" >&2
    fail=$((fail + 1))
}

engine=$(engine_build fail_fn "gate-env-probe") || exit 2
REPO="$WORK/repo"
scratch_repo_init "$REPO" shell || fail_fn "scratch repo init"

rm -rf "$REPO/.substrate/checks.d"
mkdir -p "$REPO/.substrate/checks.d"

cat > "$REPO/.substrate/checks.d/99-env-probe.sh" <<'CHECK'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' \
    "SUBSTRATE_DIR=${SUBSTRATE_DIR:-}" \
    "REPO_ROOT=${REPO_ROOT:-}" \
    "CONFIG=${CONFIG:-}" \
    "LANGMAP=${LANGMAP:-}" \
    "BASELINE=${BASELINE:-}" \
    "INVENTORY=${INVENTORY:-}" \
    "CLAIMS=${CLAIMS:-}" \
    "SUBSTRATE_CHECK_NAME=${SUBSTRATE_CHECK_NAME:-}" \
    "METRICS=${METRICS:-}" \
    > "$ENV_PROBE_OUT"
CHECK
chmod +x "$REPO/.substrate/checks.d/99-env-probe.sh"

touch "$REPO/dummy"
( cd "$REPO" && git add dummy && git -C "$REPO" commit -m init ) 2>/dev/null || true

ENV_PROBE_OUT="$WORK/bash-env.txt" bash "$REPO/substrate-engine gate" > "$WORK/bash-gate.txt" 2>&1
bash_rc=$?

ENV_PROBE_OUT="$WORK/go-env.txt" "$engine" gate > "$WORK/go-gate.txt" 2>&1
go_rc=$?

printf '  bash exit: %d, go exit: %d\n' "$bash_rc" "$go_rc"

if [ "$bash_rc" -ne "$go_rc" ]; then
    fail_fn "exit code mismatch: bash=$bash_rc go=$go_rc"
else
    printf '  [ok] exit codes match: %d\n' "$bash_rc"
    pass=$((pass + 1))
fi

cut -d= -f1 "$WORK/bash-env.txt" | sort > "$WORK/bash-keys.txt"
cut -d= -f1 "$WORK/go-env.txt" | sort > "$WORK/go-keys.txt"

if diff "$WORK/bash-keys.txt" "$WORK/go-keys.txt" > "$WORK/keys-diff.txt" 2>&1; then
    printf '  [ok] overlay var keys identical between legs\n'
    pass=$((pass + 1))
else
    printf '  [XX] overlay var key difference:\n'
    cat "$WORK/keys-diff.txt" >&2
    fail=$((fail + 1))
fi

expected_keys=(SUBSTRATE_DIR REPO_ROOT CONFIG LANGMAP BASELINE INVENTORY CLAIMS SUBSTRATE_CHECK_NAME METRICS)
all_present=1
for key in "${expected_keys[@]}"; do
    if ! grep -q "^${key}=" "$WORK/bash-env.txt"; then
        printf '  [XX] %s missing from bash env\n' "$key"
        all_present=0
    fi
    if ! grep -q "^${key}=" "$WORK/go-env.txt"; then
        printf '  [XX] %s missing from go env\n' "$key"
        all_present=0
    fi
done
if [ "$all_present" -eq 1 ]; then
    printf '  [ok] all 9 overlay var keys present in both legs\n'
    pass=$((pass + 1))
else
    fail=$((fail + 1))
fi

if [ "$fail" -gt 0 ]; then
    printf 'gate-env-probe: %d scenarios green, %d failed\n' "$pass" "$fail"
    exit 1
fi
printf 'gate-env-probe: %d scenarios green\n' "$pass"
exit 0
