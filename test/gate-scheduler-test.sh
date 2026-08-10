#!/usr/bin/env bash
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$TEST_DIR/lib"
KIT_ROOT="$(cd "$TEST_DIR/.." && pwd)"
export KIT_ROOT

source "$LIB_DIR/scratch-repo-fixture.sh"

TMPDIR="${TMPDIR:-/tmp}"
WORK=$(mktemp -d "$TMPDIR/gate-scheduler.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

fail_fn() {
    printf '  [XX] %s\n' "$1" >&2
    fail=$((fail + 1))
}

REPO="$WORK/repo"
scratch_repo_init "$REPO" shell || fail_fn "scratch repo init"

rm -rf "$REPO/.substrate/checks.d"
mkdir -p "$REPO/.substrate/checks.d"

cat > "$REPO/.substrate/checks.d/90-scheduler-a.sh" <<'CHECK'
#!/usr/bin/env bash
set -uo pipefail
source "$SUBSTRATE_DIR/gate-lib.sh"
start=$(date +%s%N)
echo "A start $start" >> "$SCHEDULER_STAMPS"
sleep 0.5
echo "A end $(date +%s%N)" >> "$SCHEDULER_STAMPS"
CHECK
chmod +x "$REPO/.substrate/checks.d/90-scheduler-a.sh"

cat > "$REPO/.substrate/checks.d/91-scheduler-b.sh" <<'CHECK'
#!/usr/bin/env bash
set -uo pipefail
source "$SUBSTRATE_DIR/gate-lib.sh"
start=$(date +%s%N)
echo "B start $start" >> "$SCHEDULER_STAMPS"
sleep 0.1
echo "B end $(date +%s%N)" >> "$SCHEDULER_STAMPS"
CHECK
chmod +x "$REPO/.substrate/checks.d/91-scheduler-b.sh"

touch "$REPO/dummy"
( cd "$REPO" && git add dummy && git -C "$REPO" commit -m init ) 2>/dev/null || true

true > "$WORK/stamps-1.txt"
SUBSTRATE_GATE_JOBS=1 SCHEDULER_STAMPS="$WORK/stamps-1.txt" \
    bash "$REPO/substrate-engine gate" > "$WORK/bash-gate-1.txt" 2>&1
printf '  Test 1 (JOBS=1): rc=%d\n' "$?"

nstamps=$(wc -l < "$WORK/stamps-1.txt")
timestamps=$(awk '{print $NF}' "$WORK/stamps-1.txt")
prev=0
monotone=1
for ts in $timestamps; do
    if [ "$ts" -le "$prev" ]; then monotone=0; break; fi
    prev=$ts
done
if [ "$monotone" -eq 1 ] && [ "$nstamps" -ge 2 ]; then
    printf '  [ok] JOBS=1 stamps monotone (%d stamps)\n' "$nstamps"
    pass=$((pass + 1))
else
    fail_fn "JOBS=1 stamps not monotone ($nstamps stamps)"
fi

true > "$WORK/stamps-2.txt"
SUBSTRATE_GATE_JOBS=2 SCHEDULER_STAMPS="$WORK/stamps-2.txt" \
    bash "$REPO/substrate-engine gate" > "$WORK/bash-gate-2.txt" 2>&1
printf '  Test 2 (JOBS=2): rc=%d\n' "$?"

nstamps2=$(wc -l < "$WORK/stamps-2.txt")
if [ "$nstamps2" -ge 2 ]; then
    printf '  [ok] JOBS=2 executed both checks (%d stamps)\n' "$nstamps2"
    pass=$((pass + 1))
else
    fail_fn "JOBS=2 only produced $nstamps2 stamps"
fi

if [ "$fail" -gt 0 ]; then
    printf 'gate-scheduler: %d scenarios green, %d failed\n' "$pass" "$fail"
    exit 1
fi
printf 'gate-scheduler: %d scenarios green\n' "$pass"
exit 0
