#!/usr/bin/env bash
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fail() {
    printf 'release-bump-test: %s\n' "$1" >&2
    exit 1
}

new_repo() {
    local root="$1" version="$2"
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
[ "${FAIL_UPDATE:-0}" = 0 ] || exit 1
root="$(cd "$(dirname "$0")/.." && pwd)"
cp "$root/VERSION" "$root/.substrate/VERSION"
cp "$root/engine.json" "$root/.substrate/engine.json"
SH
    chmod +x "$root/bin/substrate"
    git -C "$root" init -q -b main
    git -C "$root" config user.name substrate
    git -C "$root" config user.email substrate@localhost
    git -C "$root" add .
    git -C "$root" commit -qm init
}

repo="$WORK/minor"
new_repo "$repo" 0.1.0
PATH="$repo/fake-bin:$PATH" PIN_VERSION=0.2.0 "$repo/core/release-bump.sh" minor > "$WORK/minor.out" 2>&1 
[ "$(cat "$repo/VERSION")" = 0.2.0 ] || fail "minor bump did not update VERSION"
grep -q '"version":"0.2.0"' "$repo/engine.json" || fail "minor bump did not update engine pin"
cmp "$repo/VERSION" "$repo/.substrate/VERSION" || fail "minor bump did not re-vendor VERSION"
cmp "$repo/engine.json" "$repo/.substrate/engine.json" || fail "minor bump did not re-vendor engine pin"
[ -x "$repo/build/substrate-engine" ] || fail "minor bump did not retain the built engine"
grep -q 'release-bump: 0.1.0 -> 0.2.0' "$WORK/minor.out" || fail "minor bump did not report the transition"

repo="$WORK/rollback"
new_repo "$repo" 1.2.3
PATH="$repo/fake-bin:$PATH" PIN_VERSION=1.2.4 FAIL_UPDATE=1 "$repo/core/release-bump.sh" patch > "$WORK/rollback.out" 2>&1 && fail "failed guarded update was accepted"
[ "$(cat "$repo/VERSION")" = 1.2.3 ] || fail "failed guarded update did not restore VERSION"
grep -q '"version":"1.2.3"' "$repo/engine.json" || fail "failed guarded update did not restore engine pin"

repo="$WORK/refuse"
new_repo "$repo" 2.0.0
PATH="$repo/fake-bin:$PATH" PIN_VERSION=1.9.9 "$repo/core/release-bump.sh" 1.9.9 > "$WORK/refuse.out" 2>&1 && fail "version downgrade was accepted"
grep -q 'must be greater than 2.0.0' "$WORK/refuse.out" || fail "downgrade refusal did not name the current version"
[ "$(cat "$repo/VERSION")" = 2.0.0 ] || fail "downgrade refusal changed VERSION"

printf 'release-bump-test: bump, re-vendor, rollback, and downgrade scenarios green\n'
