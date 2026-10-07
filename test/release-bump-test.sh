#!/usr/bin/env bash
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export JJ_USER=substrate JJ_EMAIL=substrate@localhost
cd "$WORK" || exit 9

fail() {
    printf 'release-bump-test: %s\n' "$1" >&2
    exit 1
}

new_repo() {
    local root="$1" version="$2" vcs="${3:-git}"
    mkdir -p "$root/core" "$root/bin" "$root/cmd/substrate-engine" "$root/.substrate" "$root/fake-bin"
    cp "$KIT_ROOT/core/release-bump.sh" "$root/core/release-bump.sh"
    printf '%s\n' "$version" > "$root/VERSION"
    printf '{"version":"%s","binary_sha256":"old"}\n' "$version" > "$root/engine.json"
    cp "$root/VERSION" "$root/.substrate/VERSION"
    cp "$root/engine.json" "$root/.substrate/engine.json"
    cat > "$root/fake-bin/go" <<'SH'
#!/usr/bin/env bash
out=""
while [ "$#" -gt 0 ]; do
    if [ "$1" = -o ]; then
        out="$2"
        break
    fi
    shift
done
[ -n "$out" ] || exit 2
cat > "$out" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = pin ] && [ "\${2:-}" = emit ]; then
    printf '{"version":"%s","binary_sha256":"%064d"}\\n' "${PIN_VERSION:?}" 0
    exit 0
fi
exit 2
EOF
chmod +x "$out"
SH
    chmod +x "$root/fake-bin/go"
    cat > "$root/bin/substrate" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = update ] || exit 2
root="$(cd "$(dirname "$0")/.." && pwd)"
cp "$root/VERSION" "$root/.substrate/VERSION"
cp "$root/engine.json" "$root/.substrate/engine.json"
[ "${FAIL_UPDATE:-0}" = 0 ] || exit 1
SH
    chmod +x "$root/bin/substrate"
    printf '#!/usr/bin/env bash\nexec jj git push "$@"\n' > "$root/.substrate/gated-push.sh"
    printf 'build/\n' > "$root/.gitignore"
    git init -q --bare "$root.git"
    git -C "$root" init -q -b main
    git -C "$root" config user.name substrate
    git -C "$root" config user.email substrate@localhost
    git -C "$root" remote add origin "$root.git"
    git -C "$root" add .
    git -C "$root" commit -qm init
    git -C "$root" push -q origin main
    if [ "$vcs" = jj ]; then
        (cd "$root" && jj git init --colocate && jj bookmark track main --remote origin) >/dev/null 2>&1 || fail "jj fixture init failed"
    fi
}

assert_released() {
    local repo="$1" version="$2"
    [ "$(cat "$repo/VERSION")" = "$version" ] || fail "bump did not update VERSION to $version"
    grep -q "\"version\":\"$version\"" "$repo/engine.json" || fail "bump did not update engine pin"
    cmp "$repo/VERSION" "$repo/.substrate/VERSION" || fail "bump did not re-vendor VERSION"
    cmp "$repo/engine.json" "$repo/.substrate/engine.json" || fail "bump did not re-vendor engine pin"
    [ -x "$repo/build/substrate-engine" ] || fail "bump did not retain the built engine"
    [ -z "$(git -C "$repo" status --porcelain)" ] || fail "bump left the tree dirty"
    [ "$(git -C "$repo.git" log -1 --format=%s main)" = "chore(release): v$version" ] || fail "bump did not push the release commit"
    [ "$(git -C "$repo.git" show main:VERSION)" = "$version" ] || fail "pushed release commit lacks VERSION $version"
    [ "$(git -C "$repo.git" show main:.substrate/VERSION)" = "$version" ] || fail "pushed release commit lacks the re-vendored kit"
}

repo="$WORK/minor"
new_repo "$repo" 0.1.0
PATH="$repo/fake-bin:$PATH" PIN_VERSION=0.2.0 "$repo/core/release-bump.sh" minor > "$WORK/minor.out" 2>&1 || fail "minor bump failed: $(cat "$WORK/minor.out")"
assert_released "$repo" 0.2.0
grep -q 'release-bump: 0.1.0 -> 0.2.0' "$WORK/minor.out" || fail "minor bump did not report the transition"

repo="$WORK/jj"
new_repo "$repo" 0.3.0 jj
PATH="$repo/fake-bin:$PATH" PIN_VERSION=0.3.1 "$repo/core/release-bump.sh" patch > "$WORK/jj.out" 2>&1 || fail "jj bump failed: $(cat "$WORK/jj.out")"
assert_released "$repo" 0.3.1
[ "$(jj -R "$repo" log -r @ --no-graph -T empty)" = true ] || fail "jj bump left the working copy dirty"

repo="$WORK/dirty"
new_repo "$repo" 0.5.0
printf 'wip\n' > "$repo/wip.txt"
PATH="$repo/fake-bin:$PATH" PIN_VERSION=0.6.0 "$repo/core/release-bump.sh" minor > "$WORK/dirty.out" 2>&1 && fail "bump over a dirty tree was accepted"
grep -q 'working tree has changes' "$WORK/dirty.out" || fail "dirty refusal did not name the cause"
[ "$(cat "$repo/VERSION")" = 0.5.0 ] || fail "dirty refusal changed VERSION"

repo="$WORK/rollback"
new_repo "$repo" 1.2.3
PATH="$repo/fake-bin:$PATH" PIN_VERSION=1.2.4 FAIL_UPDATE=1 "$repo/core/release-bump.sh" patch > "$WORK/rollback.out" 2>&1 && fail "failed guarded update was accepted"
[ "$(cat "$repo/VERSION")" = 1.2.3 ] || fail "failed guarded update did not restore VERSION"
grep -q '"version":"1.2.3"' "$repo/engine.json" || fail "failed guarded update did not restore engine pin"
cmp "$repo/VERSION" "$repo/.substrate/VERSION" || fail "failed guarded update did not restore vendored VERSION"
cmp "$repo/engine.json" "$repo/.substrate/engine.json" || fail "failed guarded update did not restore vendored engine pin"

repo="$WORK/refuse"
new_repo "$repo" 2.0.0
PATH="$repo/fake-bin:$PATH" PIN_VERSION=1.9.9 "$repo/core/release-bump.sh" 1.9.9 > "$WORK/refuse.out" 2>&1 && fail "version downgrade was accepted"
grep -q 'must be greater than 2.0.0' "$WORK/refuse.out" || fail "downgrade refusal did not name the current version"
[ "$(cat "$repo/VERSION")" = 2.0.0 ] || fail "downgrade refusal changed VERSION"

printf 'release-bump-test: bump, commit, push, re-vendor, rollback, and refusal scenarios green\n'
