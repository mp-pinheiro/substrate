#!/usr/bin/env bash
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$TEST_DIR/lib"
source "$LIB_DIR/engine-fixture.sh"
export LC_ALL=C
export SUBSTRATE_NO_USER_HARNESS=1

PASS=0; FAIL=0
ok()  { printf '  [ok] %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  [XX] %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

T=$(mktemp -d) || exit 9
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"
mkdir -p "$HOME" || exit 9

real_bin=$(engine_build bad "transaction-rollback") || exit 2

mk_git_checkpoint_fixture() {
    local d="$1"
    mkdir -p "$d" && cd "$d" || return 1
    git init -q --initial-branch=main
    git config user.name substrate
    git config user.email substrate@localhost
    printf '#!/usr/bin/env bash\nprintf "ok\\n"\n' > owned.sh
    chmod +x owned.sh
    "$KIT_ROOT/bin/substrate" init --profile shell --vcs git >/dev/null 2>&1 || return 1
    printf '{"probe:alpha":10}\n' > .git/probe-metrics.json
    git add -A && git commit -qm 'chore: initialize'
    substrate-engine gate --update-baseline >/dev/null 2>&1 || return 1
    git add substrate-baseline.json && git commit -qm 'chore: establish baseline'
    printf 'printf "changed\\n"\n' >> owned.sh
}

mk_jj_restructure_fixture() {
    local d="$1"
    mkdir -p "$d" && cd "$d" || return 1
    jj config set --user user.name substrate >/dev/null 2>&1
    jj config set --user user.email substrate@localhost >/dev/null 2>&1
    git init -q --initial-branch=main
    jj git init --colocate . >/dev/null 2>&1 || return 1
    printf '#!/usr/bin/env bash\nprintf "ok\\n"\n' > script.sh
    chmod +x script.sh
    "$KIT_ROOT/bin/substrate" init --profile shell --vcs jj >/dev/null 2>&1 || return 1
    substrate-engine gate --update-baseline >/dev/null 2>&1 || return 1
    jj commit -m 'chore: initialize' >/dev/null 2>&1 || return 1
    printf 'printf "changed\\n"\n' >> script.sh
    substrate-engine checkpoint --message 'feat(shell): add script' --path script.sh >/dev/null 2>&1 || return 1
}

printf 'transaction-rollback: checkpoint\n'

d="$T/ck-go"; mk_git_checkpoint_fixture "$d"
(cd "$d" && "$real_bin" checkpoint --message 'feat(x): checkpoint' --path owned.sh) >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok "checkpoint: engine succeeds (rc=$rc)" || bad "checkpoint: engine failed (rc=$rc)"

printf '\ntransaction-rollback: restructure\n'

d="$T/rs-go"; mk_jj_restructure_fixture "$d"
change=$(cd "$d" && jj log -r @- --no-graph -T 'change_id')
(cd "$d" && "$real_bin" restructure --op describe --revision "$change" --message 'feat(shell): describe' --allow-change "$change") >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok "restructure: engine succeeds (rc=$rc)" || bad "restructure: engine failed (rc=$rc)"

if [ "$FAIL" -gt 0 ]; then
    printf '\ntransaction-rollback: %d passed, %d failed\n' "$PASS" "$FAIL"
    exit 1
fi
printf '\ntransaction-rollback: %d passed\n' "$PASS"
exit 0
