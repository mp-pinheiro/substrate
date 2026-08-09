#!/usr/bin/env bash
# Transaction rollback switch oracle: SUBSTRATE_ENGINE=bash|go|auto for the
# checkpoint and restructure verbs. Delegation scenarios activate in W2/W3
# when the probes land; at W1 only bash-leg scenarios are active.
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$TEST_DIR/lib"
source "$LIB_DIR/engine-fixture.sh"
export LC_ALL=C
export SUBSTRATE_NO_USER_HARNESS=1

PASS=0; FAIL=0; SKIP=0
ok()  { printf '  [ok] %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  [XX] %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
skip() { printf '  [--] %s (delegation probe not yet active)\n' "$1"; SKIP=$((SKIP + 1)); }

T=$(mktemp -d) || exit 9
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"
mkdir -p "$HOME" || exit 9

TRIPWIRE="$T/bin/substrate-engine"
MARKER="$T/tripwire.log"
mkdir -p "$T/bin" || exit 9
cat > "$TRIPWIRE" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$MARKER"
exit 99
SH
chmod +x "$TRIPWIRE" || exit 9

real_bin=$(engine_build bad "transaction-rollback") || exit 2
fired() { [ -s "$MARKER" ]; }
has_probe() { grep -q 'substrate_engine_supports' "$KIT_ROOT/.substrate/$1" 2>/dev/null; }

# ── checkpoint fixtures ─────────────────────────────────────

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
    .substrate/gate.sh --update-baseline >/dev/null 2>&1 || return 1
    git add substrate-baseline.json && git commit -qm 'chore: establish baseline'
    printf 'printf "changed\\n"\n' >> owned.sh
}

run_chk() {
    local d="$1" mode="$2" bin="$3"; shift 3
    : > "$MARKER"
    (cd "$d" && export SUBSTRATE_ENGINE="$mode" SUBSTRATE_ENGINE_BIN="$bin" && ./.substrate/checkpoint.sh "$@") >/dev/null
    echo "$?"
}

printf 'transaction-rollback: checkpoint\n'

# (a) bash
d="$T/ck-bash"; mk_git_checkpoint_fixture "$d"
rc=$(run_chk "$d" bash "$TRIPWIRE" --message 'feat(x): bash' --path owned.sh)
fired && bad "checkpoint: bash reached engine" || { [ "$rc" -eq 0 ] && ok "checkpoint: bash leg (rc=$rc)" || bad "checkpoint: bash failed (rc=$rc)"; }

# (b) go delegates (W2)
if has_probe "checkpoint.sh"; then
    d="$T/ck-go"; mk_git_checkpoint_fixture "$d"
    rc=$(run_chk "$d" go "$TRIPWIRE" --message 'feat(x): go' --path owned.sh)
    fired && ok "checkpoint: go dispatches (rc=$rc)" || bad "checkpoint: go did not reach engine"
else skip "checkpoint: SUBSTRATE_ENGINE=go"; fi

# (c) go no binary fails closed (W2)
if has_probe "checkpoint.sh"; then
    d="$T/ck-nobin"; mk_git_checkpoint_fixture "$d"
    rc=$(run_chk "$d" go "$T/absent-engine" --message 'feat(x): go-nobin' --path owned.sh)
    [ "$rc" -ne 0 ] && ok "checkpoint: go no binary fails closed (rc=$rc)" || bad "checkpoint: go no binary rc=$rc"
else skip "checkpoint: SUBSTRATE_ENGINE=go no binary"; fi

# (d) auto fallback (W2)
if has_probe "checkpoint.sh"; then
    d="$T/ck-auto"; mk_git_checkpoint_fixture "$d"
    rc=$(run_chk "$d" auto "$T/absent-engine" --message 'feat(x): auto-fb' --path owned.sh)
    fired && bad "checkpoint: auto reached engine with absent binary" || { [ "$rc" -eq 0 ] && ok "checkpoint: auto fallback (rc=$rc)" || bad "checkpoint: auto failed (rc=$rc)"; }
else skip "checkpoint: SUBSTRATE_ENGINE=auto"; fi

# (e) auto delegates (W2)
if has_probe "checkpoint.sh"; then
    d="$T/ck-auto-real"; mk_git_checkpoint_fixture "$d"
    rc=$(run_chk "$d" auto "$real_bin" --message 'feat(x): auto-real' --path owned.sh)
    [ "$rc" -eq 0 ] && ok "checkpoint: auto delegates (rc=$rc)" || bad "checkpoint: auto delegates failed (rc=$rc)"
else skip "checkpoint: SUBSTRATE_ENGINE=auto (real)"; fi

# ── restructure fixtures ────────────────────────────────────

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
    .substrate/gate.sh --update-baseline >/dev/null 2>&1 || return 1
    jj commit -m 'chore: initialize' >/dev/null 2>&1 || return 1
    printf 'printf "changed\\n"\n' >> script.sh
    .substrate/checkpoint.sh --message 'feat(shell): add script' --path script.sh >/dev/null 2>&1 || return 1
}

run_rs() {
    local d="$1" mode="$2" bin="$3" change="$4"; shift 4
    : > "$MARKER"
    (cd "$d" && export SUBSTRATE_ENGINE="$mode" SUBSTRATE_ENGINE_BIN="$bin" && ./.substrate/restructure.sh --op describe --revision "$change" --message 'feat(shell): describe' --allow-change "$change" "$@") >/dev/null 2>&1
    echo "$?"
}

printf '\ntransaction-rollback: restructure\n'

# (f) bash
d="$T/rs-bash"; mk_jj_restructure_fixture "$d"
change=$(cd "$d" && jj log -r @- --no-graph -T 'change_id')
rc=$(run_rs "$d" bash "$TRIPWIRE" "$change")
fired && bad "restructure: bash reached engine" || { [ "$rc" -eq 0 ] && ok "restructure: bash leg (rc=$rc)" || bad "restructure: bash failed (rc=$rc)"; }

# (g) go delegates (W3)
if has_probe "restructure.sh"; then
    d="$T/rs-go"; mk_jj_restructure_fixture "$d"
    change=$(cd "$d" && jj log -r @- --no-graph -T 'change_id')
    rc=$(run_rs "$d" go "$TRIPWIRE" "$change")
    fired && ok "restructure: go dispatches (rc=$rc)" || bad "restructure: go did not reach engine"
else skip "restructure: SUBSTRATE_ENGINE=go"; fi

# (h) go no binary fails closed (W3)
if has_probe "restructure.sh"; then
    d="$T/rs-nobin"; mk_jj_restructure_fixture "$d"
    change=$(cd "$d" && jj log -r @- --no-graph -T 'change_id')
    rc=$(run_rs "$d" go "$T/absent-engine" "$change")
    [ "$rc" -ne 0 ] && ok "restructure: go no binary fails closed (rc=$rc)" || bad "restructure: go no binary rc=$rc"
else skip "restructure: SUBSTRATE_ENGINE=go no binary"; fi

# (i) auto delegates (W3)
if has_probe "restructure.sh"; then
    d="$T/rs-auto-real"; mk_jj_restructure_fixture "$d"
    change=$(cd "$d" && jj log -r @- --no-graph -T 'change_id')
    rc=$(run_rs "$d" auto "$real_bin" "$change")
    [ "$rc" -eq 0 ] && ok "restructure: auto delegates (rc=$rc)" || bad "restructure: auto delegates failed (rc=$rc)"
else skip "restructure: SUBSTRATE_ENGINE=auto (real)"; fi

if [ "$FAIL" -gt 0 ]; then
    printf '\ntransaction-rollback: %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
    exit 1
fi
printf '\ntransaction-rollback: %d passed, %d skipped\n' "$PASS" "$SKIP"
exit 0
