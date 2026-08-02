#!/usr/bin/env bash
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"
export SUBSTRATE_NO_USER_HARNESS=1
mkdir -p "$HOME"

fail() { printf 'gitleaks-deep-test FAIL: %s\n' "$1" >&2; exit 1; }

command -v gitleaks >/dev/null 2>&1 || fail "gitleaks is not installed"
canary='ghp_'
git init -q --bare "$T/history-origin.git"
canary+='A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8'

mkdir -p "$T/history-repo"
cd "$T/history-repo" || exit 9
git init -q --initial-branch=main
git config user.name substrate
git config user.email substrate@localhost
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

mkdir -p "$T/cache-repo" "$T/fake-bin"
cd "$T/cache-repo" || exit 9
git init -q --initial-branch=main
git config user.name substrate
git config user.email substrate@localhost
printf 'safe\n' > tracked.txt
git add tracked.txt
git commit -qm 'chore: initialize'
"$KIT_ROOT/bin/substrate" init --profile base --vcs git >/dev/null 2>&1 || fail "cache fixture init failed"
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

printf 'gitleaks-deep-test: history detection, exact cache, invalidation, single CI scan green\n'
