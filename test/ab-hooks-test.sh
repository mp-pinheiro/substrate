#!/usr/bin/env bash
# Dual-leg hook parity (amendment A27): every ported hook answers the same
# stdin twice — once with SUBSTRATE_ENGINE=bash, once with SUBSTRATE_ENGINE=go —
# and stdout, stderr, exit status and watched repository state must be
# byte-identical. The bash leg records the expectation into a scratch root and
# the Go leg is judged against it, so the oracle can never go stale and never
# passes by comparing an implementation against itself.
# The engine binary is built here into a unique directory (amendments A1, A25):
# no PATH assumption, no `just`, no shared /tmp binary to hit ETXTBSY.
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/ab-diff.sh
source "$KIT_ROOT/test/lib/ab-diff.sh"

export LC_ALL=C
export SUBSTRATE_NO_USER_HARNESS=1

command -v jj >/dev/null 2>&1 || { printf 'ab-hooks-test: jj is required\n' >&2; exit 9; }
command -v go >/dev/null 2>&1 || { printf 'ab-hooks-test: go is required\n' >&2; exit 9; }
export JJ_USER=substrate JJ_EMAIL=substrate@localhost

T=$(mktemp -d) || exit 9
T=$(cd "$T" && pwd -P) || exit 9
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"
mkdir -p "$HOME" || exit 9

BUILD="$T/engine"
mkdir -p "$BUILD" || exit 9
( cd "$KIT_ROOT" && go build -o "$BUILD/substrate-engine" ./cmd/substrate-engine ) \
    || { printf 'ab-hooks-test: engine build failed\n' >&2; exit 9; }
export SUBSTRATE_ENGINE_BIN="$BUILD/substrate-engine"

# One vendored template, copied per scenario: init is slow, cp is not.
TEMPLATE="$T/template"
mkdir -p "$TEMPLATE" || exit 9
(
    cd "$TEMPLATE" || exit 9
    git init -q --initial-branch=main
    printf 'seed\n' > README.md
    "$KIT_ROOT/bin/substrate" init --profile shell
) >/dev/null 2>&1 || { printf 'ab-hooks-test: template init failed\n' >&2; exit 9; }
[ -f "$TEMPLATE/.substrate/engine-shim.sh" ] \
    || { printf 'ab-hooks-test: template lacks engine-shim.sh — re-vendor first\n' >&2; exit 9; }

STUB_PUSH_GATE='gate red: 60-shellcheck.sh'

# WHY: written here rather than copied — `substrate init` seeds protected_paths
# and contracts empty, which would make those guard branches vacuous.
write_fixture_config() {
    cat > "$1" <<'JSON'
{
  "version": 1,
  "profiles": ["base"],
  "inventory": "auto",
  "unscanned": ["*.md", "**/*.md", ".substrate/**", ".omp/**"],
  "protected_paths": ["secrets/**", "*.pem"],
  "contracts": [{"name": "api", "regen": "make api", "paths": ["generated/api"]}],
  "comment": { "allow_tags": ["SAFETY:", "WHY:", "PERF:", "HACK:"] },
  "budgets": { "max_file_lines": 500 },
  "duplication": { "min_tokens": 35 },
  "checks": { "disabled": [] }
}
JSON
}

seed_repo() {
    local repo="$1" vcs="${2:-jj}"
    mkdir -p "$repo" || return 1
    cp -R "$TEMPLATE/.substrate" "$repo/.substrate" || return 1
    write_fixture_config "$repo/substrate.json" || return 1
    printf 'seed\n' > "$repo/README.md" || return 1
    printf 'printf "owned\\n"\n' > "$repo/owned.sh" || return 1
    printf '{\n  "metrics": {},\n  "direction": {}\n}\n' > "$repo/substrate-baseline.json" || return 1
    (
        cd "$repo" || exit 9
        git init -q --initial-branch=main || exit 9
        git config user.email substrate@localhost || exit 9
        git config user.name substrate || exit 9
        if [ "$vcs" = jj ]; then
            jj git init --colocate . || exit 9
            jj commit -m 'chore: seed hook fixture' || exit 9
        else
            git add -A || exit 9
            git commit -qm 'chore: seed hook fixture' || exit 9
        fi
    ) >/dev/null 2>&1
}

stub_push_gate() {
    cat > "$1/.substrate/push-gate.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "$STUB_PUSH_GATE"
exit "\${AB_PUSH_GATE_EXIT:-1}"
SH
    chmod +x "$1/.substrate/push-gate.sh"
}

stub_checkpoint() {
    cat > "$1/.substrate/checkpoint.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"commit":"fedcba9876543210fedcba9876543210fedcba98","status":"passed"}'
exit 0
SH
    chmod +x "$1/.substrate/checkpoint.sh"
}

# hook <name> <payload> [argv...] — one measured run against the vendored hook
hook_scenario() {
    local name="$1" script="$2" payload="$3" vcs="$4" prepare="$5"
    shift 5
    local repo session
    ab_begin "$name" || return 1
    repo="$AB_SCENARIO_DIR/repo"
    session="ab-hooks-session"
    if ! seed_repo "$repo" "$vcs"; then
        ab_fail "seed failed"
        ab_end
        return 1
    fi
    if [ -n "$prepare" ] && ! "$prepare" "$repo" "$session"; then
        ab_fail "prepare $prepare failed"
        ab_end
        return 1
    fi
    ab_mask "$repo" '<REPO>'
    ab_mask "$T" '<TMP>'
    ab_mask "$session" '<SESSION>'
    ab_watch .git/substrate/agent-sessions
    payload="${payload//__SESSION__/$session}"
    ab_run "$repo" "$payload" bash ".substrate/$script" "$@"
    ab_end
}

prepare_none() { :; }

prepare_corrupt_config() {
    printf 'not json at all\n' > "$1/substrate.json"
}

prepare_symlink() {
    ln -s README.md "$1/link.md"
}

prepare_slop_file() {
    cat > "$1/slop.sh" <<'SH'
#!/usr/bin/env bash
printf 'setup\n'
# now we check the thing
printf 'hi\n'
SH
}

prepare_clean_file() {
    printf '#!/usr/bin/env bash\nprintf "hi\\n"\n' > "$1/clean.sh"
}

prepare_push_stub() {
    stub_push_gate "$1"
}

prepare_lifecycle_started() {
    printf '{"session_id":"%s"}\n' "$2" \
        | ( cd "$1" && bash .substrate/hooks/agent-lifecycle.sh start ) >/dev/null 2>&1
}

prepare_lifecycle_observed() {
    prepare_lifecycle_started "$@" || return 1
    printf 'printf "edited\\n"\n' >> "$1/owned.sh"
    printf '{"session_id":"%s"}\n' "$2" \
        | ( cd "$1" && bash .substrate/hooks/agent-lifecycle.sh observe ) >/dev/null 2>&1
}

prepare_lifecycle_pending() {
    prepare_lifecycle_observed "$@" || return 1
    stub_checkpoint "$1"
}

pp() { printf '{"tool_input":{"file_path":"%s"}}' "$1"; }
pc() { printf '{"tool_input":{"command":%s},"session_id":"__SESSION__"}' "$1"; }

matrix() {
    # protect-paths
    hook_scenario pp-benign        hooks/protect-paths.sh "$(pp 'README.md')"                 jj prepare_none
    hook_scenario pp-baseline      hooks/protect-paths.sh "$(pp 'substrate-baseline.json')"   jj prepare_none
    hook_scenario pp-nested        hooks/protect-paths.sh "$(pp 'deep/substrate-baseline.json')" jj prepare_none
    hook_scenario pp-vendored      hooks/protect-paths.sh "$(pp '.substrate/gate.sh')"        jj prepare_none
    hook_scenario pp-governance    hooks/protect-paths.sh "$(pp 'CLAUDE.md')"                 jj prepare_none
    hook_scenario pp-protected     hooks/protect-paths.sh "$(pp 'secrets/token.txt')"         jj prepare_none
    hook_scenario pp-symlink       hooks/protect-paths.sh "$(pp 'link.md')"                   jj prepare_symlink
    hook_scenario pp-corrupt       hooks/protect-paths.sh "$(pp 'README.md')"                 jj prepare_corrupt_config
    hook_scenario pp-nopath        hooks/protect-paths.sh '{"tool_input":{}}'                           jj prepare_none

    # protect-command
    hook_scenario pc-benign        hooks/protect-command.sh "$(pc '"ls -la"')"                        jj prepare_none
    hook_scenario pc-commit        hooks/protect-command.sh "$(pc '"jj commit -m x"')"                jj prepare_none
    hook_scenario pc-gitcommit     hooks/protect-command.sh "$(pc '"git commit -m x"')"               jj prepare_none
    hook_scenario pc-vendored-ckpt hooks/protect-command.sh "$(pc '".substrate/checkpoint.sh --x"')"  jj prepare_none
    hook_scenario pc-ckpt-nosess   hooks/protect-command.sh '{"tool_input":{"command":"substrate checkpoint --message x"}}' jj prepare_none
    hook_scenario pc-ckpt-badsess  hooks/protect-command.sh "$(pc '"substrate checkpoint --session other --message x"')" jj prepare_none
    hook_scenario pc-ckpt-ok       hooks/protect-command.sh "$(pc '"substrate checkpoint --session __SESSION__ --message x"')" jj prepare_none
    hook_scenario pc-baseline      hooks/protect-command.sh "$(pc '"echo x --update-baseline"')"      jj prepare_none
    hook_scenario pc-verify-piped  hooks/protect-command.sh "$(pc '"substrate verify | tail -1"')"    jj prepare_none
    hook_scenario pc-verify-plain  hooks/protect-command.sh "$(pc '"substrate verify"')"              jj prepare_none
    hook_scenario pc-mutator       hooks/protect-command.sh "$(pc '"rm -rf .substrate"')"             jj prepare_none
    hook_scenario pc-redirect      hooks/protect-command.sh "$(pc '"echo x > substrate-baseline.json"')" jj prepare_none
    hook_scenario pc-multiline     hooks/protect-command.sh "$(pc '"echo one\njj commit -m x"')"      jj prepare_none
    hook_scenario pc-multiline-ok  hooks/protect-command.sh "$(pc '"echo commit\necho jj"')"          jj prepare_none
    hook_scenario pc-corrupt       hooks/protect-command.sh "$(pc '"echo hi"')"                       jj prepare_corrupt_config

    # enforce-jj
    hook_scenario jj-mutating      hooks/enforce-jj.sh "$(pc '"git add ."')"           jj prepare_none
    hook_scenario jj-readonly      hooks/enforce-jj.sh "$(pc '"git log --oneline"')"   jj prepare_none
    hook_scenario jj-push          hooks/enforce-jj.sh "$(pc '"git push origin main"')" jj prepare_none
    hook_scenario jj-push-tags     hooks/enforce-jj.sh "$(pc '"git push --tags"')"     jj prepare_none
    hook_scenario jj-git-push      hooks/enforce-jj.sh "$(pc '"jj git push"')"         jj prepare_none
    hook_scenario jj-plain-git     hooks/enforce-jj.sh "$(pc '"git add ."')"           git prepare_none

    # enforce-conventional-commits
    hook_scenario cc-bad           hooks/enforce-conventional-commits.sh "$(pc '"jj commit -m \\"bad message\\""')" jj prepare_none
    hook_scenario cc-good          hooks/enforce-conventional-commits.sh "$(pc '"jj commit -m \\"fix(x): y\\""')"   jj prepare_none
    hook_scenario cc-nomessage     hooks/enforce-conventional-commits.sh "$(pc '"jj commit"')"                      jj prepare_none
    hook_scenario cc-plain-git     hooks/enforce-conventional-commits.sh "$(pc '"jj commit -m \\"bad\\""')"         git prepare_none

    # gate-before-push
    hook_scenario gbp-skip         hooks/gate-before-push.sh "$(pc '"echo hi"')"            jj prepare_none
    hook_scenario gbp-remote       hooks/gate-before-push.sh "$(pc '"jj git push -R other"')" jj prepare_none
    hook_scenario gbp-blocked      hooks/gate-before-push.sh "$(pc '"jj git push"')"        jj prepare_push_stub

    # changed-files-scan + comment-ratchet
    hook_scenario scan-clean       hooks/changed-files-scan.sh '{}' jj prepare_clean_file
    hook_scenario scan-slop        hooks/changed-files-scan.sh '{}' jj prepare_slop_file
    hook_scenario ratchet-clean    comment-ratchet.sh '' jj prepare_clean_file clean.sh
    hook_scenario ratchet-slop     comment-ratchet.sh '' jj prepare_slop_file  slop.sh
    hook_scenario ratchet-missing  comment-ratchet.sh '' jj prepare_none       nope.sh

    # agent-lifecycle
    hook_scenario lc-start         hooks/agent-lifecycle.sh '{"session_id":"__SESSION__"}' jj prepare_none              start
    hook_scenario lc-observe-fresh hooks/agent-lifecycle.sh '{"session_id":"__SESSION__"}' jj prepare_none              observe
    hook_scenario lc-observe-owned hooks/agent-lifecycle.sh '{"session_id":"__SESSION__"}' jj prepare_lifecycle_observed observe
    hook_scenario lc-verify-none   hooks/agent-lifecycle.sh ''                             jj prepare_lifecycle_started verify ab-hooks-session
    hook_scenario lc-verify-owned  hooks/agent-lifecycle.sh ''                             jj prepare_lifecycle_observed verify ab-hooks-session
    hook_scenario lc-verify-missing hooks/agent-lifecycle.sh ''                            jj prepare_none              verify ab-hooks-session
    hook_scenario lc-complete-bad  hooks/agent-lifecycle.sh ''                             jj prepare_lifecycle_observed complete ab-hooks-session deadbeef
    hook_scenario lc-end           hooks/agent-lifecycle.sh '{"session_id":"__SESSION__"}' jj prepare_lifecycle_started end
    hook_scenario lc-usage         hooks/agent-lifecycle.sh ''                             jj prepare_none              bogus ab-hooks-session
    hook_scenario lc-badsession    hooks/agent-lifecycle.sh '{"session_id":"bad session!"}' jj prepare_none             start
    hook_scenario lc-stop-clean    hooks/agent-lifecycle.sh '{"session_id":"__SESSION__","stop_hook_active":false}' jj prepare_lifecycle_started stop
    hook_scenario lc-stop-owned    hooks/agent-lifecycle.sh '{"session_id":"__SESSION__","stop_hook_active":true}'  jj prepare_lifecycle_pending stop
}

leg() {
    local mode="$1" engine="$2"
    AB_MODE="$mode"
    AB_WORK="$T/work-$engine"
    SUBSTRATE_ENGINE="$engine"
    export AB_MODE AB_WORK AB_EXPECTED_ROOT SUBSTRATE_ENGINE
    ab_init ab-hooks || return 9
    matrix
    ab_report
}

# AB_HOOKS_EXPECTED keeps the bash-leg recording for inspection or CI upload;
# unset, it lives and dies inside the scratch tree.
AB_EXPECTED_ROOT="${AB_HOOKS_EXPECTED:-$T/expected}"
leg capture bash || { printf 'ab-hooks-test: the bash leg failed to record cleanly\n' >&2; exit 1; }
leg verify go || { printf 'ab-hooks-test: the go leg diverged from the bash leg\n' >&2; exit 1; }
printf 'ab-hooks-test: both legs agree on every scenario\n'
