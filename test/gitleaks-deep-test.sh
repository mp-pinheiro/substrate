#!/usr/bin/env bash
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/engine-fixture.sh
source "$KIT_ROOT/test/lib/engine-fixture.sh"
engine_fixture_home
export SUBSTRATE_NO_USER_HARNESS=1

fail() { printf 'gitleaks-deep-test FAIL: %s\n' "$1" >&2; exit 1; }

init_scan_repo() {
    mkdir -p "$1"
    cd "$1" || exit 9
    git init -q --initial-branch=main
    git config user.name substrate
    git config user.email substrate@localhost
}

init_tracked_repo() {
    init_scan_repo "$1"
    printf 'safe\n' > tracked.txt
    git add tracked.txt
    git commit -qm 'chore: initialize'
    "$KIT_ROOT/bin/substrate" init --profile base --vcs git >/dev/null 2>&1 || fail "$2 fixture init failed"
}

command -v gitleaks >/dev/null 2>&1 || fail "gitleaks is not installed"
command -v go >/dev/null 2>&1 || fail "go is required for the gitleaks-deep-key byte-identity oracle"
canary='ghp_'
git init -q --bare "$T/history-origin.git"
canary+='A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8'

init_scan_repo "$T/history-repo"
printf '%s\n' "$canary" > retired.txt
git add retired.txt
git commit -qm 'chore: add retired credential'
printf 'safe\n' > retired.txt
git add retired.txt
git commit -qm 'chore: retire credential'
git remote add origin "$T/history-origin.git"
git push -q -u origin main
"$KIT_ROOT/bin/substrate" init --profile base --vcs git >/dev/null 2>&1 || fail "history fixture init failed"
.substrate/gate.sh --update-baseline >/dev/null 2>&1 || fail "history fixture baseline failed"
if "$KIT_ROOT/bin/substrate" gate --deep --no-cache > "$T/history.out" 2>&1; then
    fail "deep scan missed a secret in reachable history"
fi
if ! grep -Fq 'retired.txt' "$T/history.out"; then
    cat "$T/history.out" >&2
    fail "historical finding did not name its file"
fi
if ! grep -Fq 'deep scan found potential secrets' "$T/history.out"; then
    cat "$T/history.out" >&2
    fail "historical finding was not actionable"
fi

mkdir -p "$T/fake-bin"
init_tracked_repo "$T/cache-repo" cache
export GITLEAKS_COUNT="$T/gitleaks-count"
export GITLEAKS_VERSION_FILE="$T/gitleaks-version"
printf 'fake-v1\n' > "$GITLEAKS_VERSION_FILE"
: > "$GITLEAKS_COUNT"
cat > "$T/fake-bin/gitleaks" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
    version)
        cat "$GITLEAKS_VERSION_FILE"
        ;;
    git)
        printf '%s\n' "$*" >> "$GITLEAKS_COUNT"
        ;;
    *)
        exit 2
        ;;
esac
SH
chmod +x "$T/fake-bin/gitleaks"
export PATH="$T/fake-bin:$PATH"

.substrate/gitleaks-deep.sh > "$T/deep.out" 2>&1 || fail "first deep scan failed"
[ "$(wc -l < "$GITLEAKS_COUNT")" -eq 1 ] || fail "first deep scan did not invoke gitleaks once"
grep -Fq 'full reachable history passed' "$T/deep.out" || fail "first deep scan did not report a full scan"
.substrate/gitleaks-deep.sh > "$T/deep.out" 2>&1 || fail "cached deep scan failed"
[ "$(wc -l < "$GITLEAKS_COUNT")" -eq 1 ] || fail "exact cache hit reran gitleaks"
grep -Fq 'exact-state cache hit' "$T/deep.out" || fail "cache hit was not reported"
.substrate/gitleaks-deep.sh --no-cache >/dev/null 2>&1 || fail "no-cache deep scan failed"
[ "$(wc -l < "$GITLEAKS_COUNT")" -eq 2 ] || fail "--no-cache did not force a scan"

git tag cache-ref
.substrate/gitleaks-deep.sh >/dev/null 2>&1 || fail "ref-invalidated deep scan failed"
[ "$(wc -l < "$GITLEAKS_COUNT")" -eq 3 ] || fail "ref change did not invalidate the cache"
printf '[allowlist]\ndescription = "cache probe"\n' > .gitleaks.toml
.substrate/gitleaks-deep.sh >/dev/null 2>&1 || fail "config-invalidated deep scan failed"
[ "$(wc -l < "$GITLEAKS_COUNT")" -eq 4 ] || fail "gitleaks config change did not invalidate the cache"
printf 'fake-v2\n' > "$GITLEAKS_VERSION_FILE"
.substrate/gitleaks-deep.sh >/dev/null 2>&1 || fail "version-invalidated deep scan failed"
[ "$(wc -l < "$GITLEAKS_COUNT")" -eq 5 ] || fail "gitleaks version change did not invalidate the cache"

scan_steps=$(yq -r '[.jobs.gate.steps[] | select(.run == ".substrate/gitleaks-deep.sh")] | length' \
    "$KIT_ROOT/core/ci/github-gate.yml")
[ "$scan_steps" -eq 1 ] || fail "consumer CI does not own exactly one full-history scan"
if grep -Fq 'gitleaks/gitleaks-action' "$KIT_ROOT/core/ci/github-gate.yml"; then
    fail "consumer CI still carries a second full-history scanner"
fi

ENGINE_BIN=$(engine_build fail go "$(cat VERSION)") || exit 1

assert_key_parity() {
    local repo="$1" label="$2" bash_key go_key
    bash_key=$(cd "$repo" && source "$KIT_ROOT/core/gitleaks-lib.sh" && gitleaks_deep_key_v1) \
        || fail "$label: bash key computation failed"
    go_key=$(cd "$repo" && "$ENGINE_BIN" gitleaks-deep-key) \
        || fail "$label: go key computation failed"
    [ "$bash_key" = "$go_key" ] || fail "$label: bash key $bash_key != go key $go_key"
    KEY_PARITY_VALUE="$bash_key"
}

mkdir -p "$T/key-empty-repo"
(cd "$T/key-empty-repo" && git init -q --initial-branch=main) || fail "empty repo init failed"
# WHY: an unborn HEAD makes `git rev-parse HEAD` echo the literal argument to
# stdout before failing, so the raw stream is "HEAD\n", not empty input.
UNBORN_HEAD_REFS_SHA256=34d6a94dacb895403529caac12a19aed745c6caca7a8d0f4ed631999044f76e8
raw_refs_hash=$(cd "$T/key-empty-repo" && {
    git for-each-ref --format='%(refname) %(objectname)' refs/heads refs/tags refs/remotes
    git rev-parse HEAD 2>/dev/null || true
} | LC_ALL=C sort -u | sha256sum | cut -d ' ' -f 1)
[ "$raw_refs_hash" = "$UNBORN_HEAD_REFS_SHA256" ] \
    || fail "empty repo: refs component is not the documented unborn-HEAD sha256"
assert_key_parity "$T/key-empty-repo" "empty repo, no refs"

init_scan_repo "$T/key-tagged-repo"
printf 'x\n' > f.txt
git add f.txt
git commit -qm 'chore: initialize'
git tag key-parity-tag
cd "$T" || exit 9
assert_key_parity "$T/key-tagged-repo" "tagged repo, no gitleaks.toml"
key_no_config="$KEY_PARITY_VALUE"

printf '[allowlist]\ndescription = "key parity probe"\n' > "$T/key-tagged-repo/.gitleaks.toml"
assert_key_parity "$T/key-tagged-repo" "tagged repo, gitleaks.toml present"
[ "$KEY_PARITY_VALUE" != "$key_no_config" ] \
    || fail "adding .gitleaks.toml did not change the deep-scan key on either leg"

rm -f "$T/key-tagged-repo/.gitleaks.toml"
assert_key_parity "$T/key-tagged-repo" "tagged repo, gitleaks.toml removed"
[ "$KEY_PARITY_VALUE" = "$key_no_config" ] \
    || fail "removing .gitleaks.toml did not restore the original deep-scan key"

DUAL_REPO="$T/dual-leg-repo"
init_tracked_repo "$DUAL_REPO" dual-leg
cd "$T" || exit 9
DUAL_SCRIPT="$DUAL_REPO/.substrate/gitleaks-deep.sh"
export GITLEAKS_COUNT="$T/gitleaks-count-dual"
export GITLEAKS_VERSION_FILE="$T/gitleaks-version-dual"
printf 'fake-dual\n' > "$GITLEAKS_VERSION_FILE"
: > "$GITLEAKS_COUNT"

count_pre_seed=$(wc -l < "$GITLEAKS_COUNT")
env SUBSTRATE_ENGINE=bash "$DUAL_SCRIPT" >/dev/null 2>&1 || fail "dual-leg: seeding the cache failed"
count_post_seed=$(wc -l < "$GITLEAKS_COUNT")
[ "$count_post_seed" -eq "$((count_pre_seed + 1))" ] \
    || fail "dual-leg: cache seed did not invoke gitleaks exactly once"

dual_leg_diff() {
    local label="$1"
    shift
    env SUBSTRATE_ENGINE=bash "$@" >"$T/dual-out-bash" 2>"$T/dual-err-bash"
    DUAL_RC_BASH=$?
    env SUBSTRATE_ENGINE=go SUBSTRATE_ENGINE_BIN="$ENGINE_BIN" "$@" >"$T/dual-out-go" 2>"$T/dual-err-go"
    DUAL_RC_GO=$?
    [ "$DUAL_RC_BASH" -eq "$DUAL_RC_GO" ] \
        || fail "$label: exit differs (bash=$DUAL_RC_BASH go=$DUAL_RC_GO)"
    cmp -s "$T/dual-out-bash" "$T/dual-out-go" || fail "$label: stdout differs between legs"
    cmp -s "$T/dual-err-bash" "$T/dual-err-go" || fail "$label: stderr differs between legs"
}

dual_leg_diff "print-key" "$DUAL_SCRIPT" --print-key
[ "$DUAL_RC_BASH" -eq 0 ] || fail "print-key: expected exit 0, got $DUAL_RC_BASH"
[ ! -s "$T/dual-err-bash" ] || fail "print-key: wrote to stderr"
[ "$(wc -l < "$T/dual-out-bash")" -eq 1 ] || fail "print-key: did not print exactly one line"
grep -Eq '^[0-9a-f]{64}$' "$T/dual-out-bash" || fail "print-key: output is not a bare 64-hex line"

dual_leg_diff "cache-hit" "$DUAL_SCRIPT"
[ "$DUAL_RC_BASH" -eq 0 ] || fail "cache-hit: expected exit 0, got $DUAL_RC_BASH"
grep -Fq 'exact-state cache hit' "$T/dual-out-bash" || fail "cache-hit: did not report a cache hit"
[ "$(wc -l < "$GITLEAKS_COUNT")" -eq "$count_post_seed" ] \
    || fail "cache-hit: a leg reran gitleaks instead of hitting the cache"

dual_leg_diff "bad-flag usage" "$DUAL_SCRIPT" --totally-bogus-flag
[ "$DUAL_RC_BASH" -eq 2 ] || fail "bad-flag usage: expected exit 2, got $DUAL_RC_BASH"
[ ! -s "$T/dual-out-bash" ] || fail "bad-flag usage: wrote to stdout"
grep -Fq 'usage:' "$T/dual-err-bash" || fail "bad-flag usage: did not print the usage line"

printf 'gitleaks-deep-test: history detection, exact cache, invalidation, single CI scan, byte-identical deep-scan key, dual-leg parity green\n'
