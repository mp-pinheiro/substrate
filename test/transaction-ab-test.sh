#!/usr/bin/env bash
# Transaction A/B diff harness: runs checkpoint and restructure on both legs
# and asserts byte-identical stdout/stderr/exit across all 14 scenarios.
# Same pattern as test/gate-ab-test.sh but transactions have no durations
# to mask — byte comparison is direct.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$TEST_DIR/lib"
KIT_ROOT="$(cd "$TEST_DIR/.." && pwd)"

source "$LIB_DIR/engine-fixture.sh"

TMPDIR="${TMPDIR:-/tmp}"
WORK=$(mktemp -d "$TMPDIR/transaction-ab.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

fail_fn() {
    printf '  [XX] %s\n' "$1" >&2
    fail=$((fail + 1))
}

report_diff() {
    local label="$1" bash_out="$2" go_out="$3"
    if diff -u "$bash_out" "$go_out" > "$WORK/diff.txt" 2>&1; then
        printf '  [ok] %s: byte-identical\n' "$label"
        pass=$((pass + 1))
    else
        printf '  [XX] %s: content differs — see %s\n' "$label" "$WORK/diff.txt"
        fail=$((fail + 1))
        return 1
    fi
}

engine_bin=$(engine_build fail_fn "transaction-ab") || exit 2

run_checkpoint_bash() {
    local out="$1" err="$2"
    shift 2
    SUBSTRATE_ENGINE=bash bash "$KIT_ROOT/.substrate/checkpoint.sh" "$@" > "$out" 2> "$err"
}

run_checkpoint_go() {
    local out="$1" err="$2"
    shift 2
    SUBSTRATE_ENGINE=go SUBSTRATE_ENGINE_BIN="$engine_bin" \
        bash "$KIT_ROOT/.substrate/checkpoint.sh" "$@" > "$out" 2> "$err"
}

run_restructure_bash() {
    local out="$1" err="$2"
    shift 2
    SUBSTRATE_ENGINE=bash bash "$KIT_ROOT/.substrate/restructure.sh" "$@" > "$out" 2> "$err"
}

run_restructure_go() {
    local out="$1" err="$2"
    shift 2
    SUBSTRATE_ENGINE=go SUBSTRATE_ENGINE_BIN="$engine_bin" \
        bash "$KIT_ROOT/.substrate/restructure.sh" "$@" > "$out" 2> "$err"
}

run_diff() {
    local label="$1" runner="$2"
    shift 2
    local bash_out="$WORK/bash-$label.txt" go_out="$WORK/go-$label.txt"
    local bash_err="$WORK/bash-$label.err" go_err="$WORK/go-$label.err"

    "$runner"_bash "$bash_out" "$bash_err" "$@"
    bash_rc=$?
    "$runner"_go "$go_out" "$go_err" "$@"
    go_rc=$?

    if [ "$bash_rc" -ne "$go_rc" ]; then
        fail_fn "$label: exit code mismatch: bash=$bash_rc go=$go_rc"
    else
        printf '  [ok] %s: exit %d matches\n' "$label" "$bash_rc"
        pass=$((pass + 1))
    fi

    report_diff "$label stdout" "$bash_out" "$go_out"
    report_diff "$label stderr" "$bash_err" "$go_err"
}

# ── Git fixture ──────────────────────────────────────────────
setup_git_repo() {
    local dir="$1"
    mkdir -p "$dir"
    cd "$dir" || exit 9
    git init -q --initial-branch=main
    git config user.name substrate
    git config user.email substrate@localhost
    printf '#!/usr/bin/env bash\nprintf "hello\\n"\n' > owned.sh
    chmod +x owned.sh
    printf '#!/usr/bin/env bash\nprintf "user\\n"\n' > user.sh
    chmod +x user.sh
    "$KIT_ROOT/bin/substrate" init --profile shell --vcs git >/dev/null 2>&1 || return 1
    cat > .substrate/checks.d/58-probe.sh <<'SH'
#!/usr/bin/env bash
probe=$(jq -r '.["probe:alpha"] // 0' .git/probe-metrics.json 2>/dev/null || printf '0')
printf '{"probe:alpha":%s}\n' "$probe"
SH
    chmod +x .substrate/checks.d/58-probe.sh
    printf '{"probe:alpha":10}\n' > .git/probe-metrics.json
    git add -A
    git commit -qm 'chore: initialize'
    .substrate/gate.sh --update-baseline >/dev/null 2>&1 || return 1
    git add substrate-baseline.json
    git commit -qm 'chore: establish baseline'
    [ -z "$(git status --porcelain=v1 --untracked-files=all)" ] || return 1
}

# ── JJ fixture ───────────────────────────────────────────────
setup_jj_repo() {
    local dir="$1"
    mkdir -p "$dir"
    cd "$dir" || exit 9
    jj config set --user user.name substrate >/dev/null 2>&1
    jj config set --user user.email substrate@localhost >/dev/null 2>&1
    git init -q --initial-branch=main
    jj git init --colocate . >/dev/null 2>&1 || return 1
    printf '#!/usr/bin/env bash\nprintf "hello\\n"\n' > owned.sh
    chmod +x owned.sh
    printf '#!/usr/bin/env bash\nprintf "user\\n"\n' > user.sh
    chmod +x user.sh
    "$KIT_ROOT/bin/substrate" init --profile shell --vcs jj >/dev/null 2>&1 || return 1
    .substrate/gate.sh --update-baseline >/dev/null 2>&1 || return 1
    jj commit -m 'chore: initialize' >/dev/null 2>&1 || return 1
}

printf 'transaction-ab: comparing bash vs go transactions\n'

# ── Scenario 1: full-repo git checkpoint ─────────────────────
printf '\n[1/14] full-repo git checkpoint\n'
d="$WORK/git-full-checkpoint"
setup_git_repo "$d"
printf 'printf "changed\\n"\n' >> "$d/owned.sh"
# Manual commit path: run checkpoint directly
run_diff "git-full-checkpoint" run_checkpoint \
    --message 'feat(shell): full git checkpoint' --path owned.sh

# ── Scenario 2: full-repo jj checkpoint ──────────────────────
printf '\n[2/14] full-repo jj checkpoint\n'
d="$WORK/jj-full-checkpoint"
setup_jj_repo "$d"
printf 'printf "changed\\n"\n' >> "$d/owned.sh"
run_diff "jj-full-checkpoint" run_checkpoint \
    --message 'feat(shell): full jj checkpoint' --path owned.sh

# ── Scenario 3: path-scoped git checkpoint with leftover ─────
printf '\n[3/14] path-scoped git checkpoint\n'
d="$WORK/git-scoped-checkpoint"
setup_git_repo "$d"
printf 'printf "changed\\n"\n' >> "$d/owned.sh"
printf 'printf "unowned-change\\n"\n' >> "$d/user.sh"
run_diff "git-scoped-checkpoint" run_checkpoint \
    --message 'fix(shell): scoped checkpoint' --path owned.sh

# ── Scenario 4: path-scoped jj checkpoint with leftover ──────
printf '\n[4/14] path-scoped jj checkpoint\n'
d="$WORK/jj-scoped-checkpoint"
setup_jj_repo "$d"
printf 'printf "changed\\n"\n' >> "$d/owned.sh"
printf 'printf "unowned-change\\n"\n' >> "$d/user.sh"
run_diff "jj-scoped-checkpoint" run_checkpoint \
    --message 'fix(shell): scoped jj checkpoint' --path owned.sh

# ── Scenario 5: checkpoint with accept-regression ────────────
printf '\n[5/14] checkpoint with accept-regression\n'
d="$WORK/git-accept-regression"
setup_git_repo "$d"
printf 'printf "changed\\n"\n' >> "$d/owned.sh"
printf '{"probe:alpha":20}\n' > "$d/.git/probe-metrics.json"
run_diff "accept-regression" run_checkpoint \
    --message 'feat(shell): accept regression' --path owned.sh \
    --accept-regression=probe:alpha --reason 'intentional metric growth'

# ── Scenario 6: checkpoint with session ──────────────────────
printf '\n[6/14] checkpoint with session\n'
d="$WORK/jj-session-checkpoint"
setup_jj_repo "$d"
printf 'printf "changed\\n"\n' >> "$d/owned.sh"
printf '{"session_id":"ab-session"}\n' | (cd "$d" && .substrate/hooks/agent-lifecycle.sh start) >/dev/null 2>&1
printf '{"session_id":"ab-session"}\n' | (cd "$d" && .substrate/hooks/agent-lifecycle.sh observe) >/dev/null 2>&1
run_diff "session-checkpoint" run_checkpoint \
    --session ab-session --message 'chore(agent): session checkpoint'

# ── Scenario 7: restructure split ────────────────────────────
printf '\n[7/14] restructure split\n'
d="$WORK/jj-restructure-split"
setup_jj_repo "$d"
printf 'printf "one\\n"\n' > "$d/a.sh"
printf 'printf "two\\n"\n' > "$d/b.sh"
chmod +x "$d/a.sh" "$d/b.sh"
(cd "$d" && .substrate/checkpoint.sh --message 'feat(shell): add both' --path a.sh --path b.sh) >/dev/null 2>&1
target=$(cd "$d" && jj log -r @- --no-graph -T 'change_id')
run_diff "restructure-split" run_restructure \
    --op split --revision "$target" --path a.sh \
    --message 'refactor(shell): isolate a' --message2 'refactor(shell): keep b' \
    --allow-change "$target"

# ── Scenario 8: restructure describe ─────────────────────────
printf '\n[8/14] restructure describe\n'
d="$WORK/jj-restructure-describe"
setup_jj_repo "$d"
printf 'printf "added\\n"\n' > "$d/new.sh"
chmod +x "$d/new.sh"
(cd "$d" && .substrate/checkpoint.sh --message 'feat(shell): add script' --path new.sh) >/dev/null 2>&1
target=$(cd "$d" && jj log -r @- --no-graph -T 'change_id')
run_diff "restructure-describe" run_restructure \
    --op describe --revision "$target" \
    --message 'feat(shell): add script renamed' --allow-change "$target"

# ── Scenario 9: restructure squash ───────────────────────────
printf '\n[9/14] restructure squash\n'
d="$WORK/jj-restructure-squash"
setup_jj_repo "$d"
printf 'printf "first\\n"\n' > "$d/x.sh"
printf 'printf "second\\n"\n' > "$d/y.sh"
chmod +x "$d/x.sh" "$d/y.sh"
(cd "$d" && .substrate/checkpoint.sh --message 'feat(shell): add x' --path x.sh) >/dev/null 2>&1
c1=$(cd "$d" && jj log -r @- --no-graph -T 'change_id')
(cd "$d" && .substrate/checkpoint.sh --message 'feat(shell): add y' --path y.sh) >/dev/null 2>&1
c2=$(cd "$d" && jj log -r @- --no-graph -T 'change_id')
run_diff "restructure-squash" run_restructure \
    --op squash --revision "$c1" --into "$c2" \
    --message 'feat(shell): merge x and y' \
    --allow-change "$c1" --allow-change "$c2"

# ── Scenario 10: restructure with session ────────────────────
printf '\n[10/14] restructure with session\n'
d="$WORK/jj-restructure-session"
setup_jj_repo "$d"
printf 'printf "session-file\\n"\n' > "$d/s.sh"
chmod +x "$d/s.sh"
printf '{"session_id":"restructure-ab-session"}\n' | (cd "$d" && .substrate/hooks/agent-lifecycle.sh start) >/dev/null 2>&1
printf '{"session_id":"restructure-ab-session"}\n' | (cd "$d" && .substrate/hooks/agent-lifecycle.sh observe) >/dev/null 2>&1
(cd "$d" && .substrate/checkpoint.sh --session restructure-ab-session --message 'feat(shell): session file') >/dev/null 2>&1
session_change=$(cd "$d" && jq -r '.sessionChanges[0] // empty' "$(git rev-parse --git-common-dir)/substrate/agent-sessions/restructure-ab-session.json")
run_diff "restructure-session" run_restructure \
    --op describe --revision "$session_change" \
    --message 'feat(shell): session file renamed' --session restructure-ab-session

# ── Scenario 11: restructure non-authored commit (rejection) ─
printf '\n[11/14] restructure non-authored rejection\n'
d="$WORK/jj-restructure-reject"
setup_jj_repo "$d"
seed=$(cd "$d" && jj log -r @- --no-graph -T 'change_id')
run_diff "restructure-reject" run_restructure \
    --op describe --revision "$seed" --message 'fix(shell): reject' \
    --allow-change some-random-change-id

# ── Scenario 12: checkpoint non-pending path (rejection) ─────
printf '\n[12/14] checkpoint non-pending rejection\n'
d="$WORK/git-checkpoint-reject-pending"
setup_git_repo "$d"
run_diff "checkpoint-non-pending" run_checkpoint \
    --message 'fix(shell): reject non-pending' --path ghost.sh

# ── Scenario 13: checkpoint governed path (rejection) ────────
printf '\n[13/14] checkpoint governed rejection\n'
d="$WORK/git-checkpoint-reject-governed"
setup_git_repo "$d"
jq '.metrics.probe = 1' "$d/substrate-baseline.json" > "$d/baseline.tmp"
mv "$d/baseline.tmp" "$d/substrate-baseline.json"
run_diff "checkpoint-governed" run_checkpoint \
    --message 'fix(shell): reject governed' --path substrate-baseline.json

# ── Scenario 14: checkpoint with --json ──────────────────────
printf '\n[14/14] checkpoint --json\n'
d="$WORK/git-checkpoint-json"
setup_git_repo "$d"
printf 'printf "changed\\n"\n' >> "$d/owned.sh"
run_diff "checkpoint-json" run_checkpoint \
    --message 'feat(shell): json checkpoint' --path owned.sh --json

if [ "$fail" -gt 0 ]; then
    printf '\ntransaction-ab: %d scenarios green, %d failed\n' "$pass" "$fail"
    exit 1
fi
printf '\ntransaction-ab: %d scenarios green\n' "$pass"
exit 0
