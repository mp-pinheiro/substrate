#!/usr/bin/env bash
# Dual-leg hook parity (amendment A27): the bash-leg recording is the
# independent oracle for the Go leg — it must be captured fresh each run,
# never hardcoded, or the harness would compare an implementation against itself.
# The engine binary is built here into a unique directory (amendments A1, A25):
# no PATH assumption, no `just`, no shared /tmp binary to hit ETXTBSY.
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/ab-diff.sh
source "$KIT_ROOT/test/lib/ab-diff.sh"
# shellcheck source=lib/ab-hooks-fixtures.sh
source "$KIT_ROOT/test/lib/ab-hooks-fixtures.sh"
# shellcheck source=lib/ab-hooks-scenarios.sh
source "$KIT_ROOT/test/lib/ab-hooks-scenarios.sh"

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

# .substrate is vendored once here; two full per-flavour templates follow below.
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

# Written here rather than copied — `substrate init` seeds protected_paths
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

seed_flavour_template() {
    local dir="$1" vcs="$2"
    mkdir -p "$dir" || return 1
    cp -R "$TEMPLATE/.substrate" "$dir/.substrate" || return 1
    write_fixture_config "$dir/substrate.json" || return 1
    printf 'seed\n' > "$dir/README.md" || return 1
    printf 'printf "owned\\n"\n' > "$dir/owned.sh" || return 1
    printf '{\n  "metrics": {},\n  "direction": {}\n}\n' > "$dir/substrate-baseline.json" || return 1
    (
        cd "$dir" || exit 9
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

# Seeded and committed once per flavour; seed_repo below is only a cp -R.
TEMPLATE_JJ="$T/template-jj"
TEMPLATE_GIT="$T/template-git"
seed_flavour_template "$TEMPLATE_JJ" jj \
    || { printf 'ab-hooks-test: jj template seed failed\n' >&2; exit 9; }
seed_flavour_template "$TEMPLATE_GIT" git \
    || { printf 'ab-hooks-test: git template seed failed\n' >&2; exit 9; }

seed_repo() {
    local repo="$1" vcs="${2:-jj}" template="$TEMPLATE_JJ"
    [ "$vcs" = jj ] || template="$TEMPLATE_GIT"
    cp -R "$template" "$repo"
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

leg() {
    local mode="$1" engine="$2"
    AB_MODE="$mode"
    AB_WORK="$T/work-$AB_LOCALE-$engine"
    SUBSTRATE_ENGINE="$engine"
    export AB_MODE AB_WORK AB_EXPECTED_ROOT SUBSTRATE_ENGINE
    ab_init ab-hooks || return 9
    matrix
    ab_report
}

# AB_HOOKS_EXPECTED keeps the bash-leg recording for inspection/CI upload;
# unset, it lives and dies in the scratch tree.
AB_HOOKS_EXPECTED_BASE="${AB_HOOKS_EXPECTED:-$T/expected}"
AB_LOCALES="${AB_LOCALES:-C en_US.UTF-8}"

overall_rc=0
for AB_LOCALE in $AB_LOCALES; do
    export LC_ALL="$AB_LOCALE"
    AB_EXPECTED_ROOT="$AB_HOOKS_EXPECTED_BASE/$AB_LOCALE"
    if ! leg capture bash; then
        printf 'ab-hooks-test: the bash leg failed to record cleanly under LC_ALL=%s\n' "$AB_LOCALE" >&2
        overall_rc=1
        continue
    fi
    if ! leg verify go; then
        printf 'ab-hooks-test: the go leg diverged from the bash leg under LC_ALL=%s\n' "$AB_LOCALE" >&2
        overall_rc=1
    fi
done
if [ "$overall_rc" -eq 0 ]; then
    printf 'ab-hooks-test: both legs agree on every scenario under every locale (%s)\n' "$AB_LOCALES"
else
    exit 1
fi
