#!/usr/bin/env bash
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$KIT_ROOT" || exit 9

fail() { printf 'kit-embed-test FAIL: %s\n' "$1" >&2; exit 1; }
ok() { printf '\033[0;32m[ok]\033[0m kit-embed-test: %s\n' "$*"; }

T=$(mktemp -d) || fail "scratch dir"
trap 'rm -rf "$T"' EXIT

GOBIN="$T/bin" go install ./cmd/substrate || fail "cmd/substrate build failed"

export HOME="$T/home" SUBSTRATE_KIT_CACHE="$T/cache"
mkdir -p "$HOME" "$SUBSTRATE_KIT_CACHE" || fail "scratch home"
"$T/bin/substrate" version >/dev/null 2>&1

root=$(find "$SUBSTRATE_KIT_CACHE/substrate/kit" -mindepth 1 -maxdepth 1 -type d -not -name '*.tmp' | head -1)
[ -n "$root" ] || fail "the binary materialized no kit under $SUBSTRATE_KIT_CACHE"

for tree in bin core profiles skills agents; do
    (cd "$KIT_ROOT" && git ls-files --cached --others --exclude-standard "$tree" \
        | while IFS= read -r f; do [ -f "$f" ] && printf '%s\n' "$f"; done \
        | LC_ALL=C sort -u) > "$T/src-$tree.txt" \
        || fail "cannot list tracked $tree"
    (cd "$root" && find "$tree" -type f | grep -vx 'bin/substrate-engine' | LC_ALL=C sort) > "$T/kit-$tree.txt" \
        || fail "cannot list materialized $tree"
    if ! diff -u "$T/src-$tree.txt" "$T/kit-$tree.txt" > "$T/diff-$tree.txt"; then
        head -20 "$T/diff-$tree.txt" >&2
        fail "$tree/ differs between the source tree and the embedded kit — a nested go.mod or an embed exclusion silently dropped files"
    fi
done

for f in VERSION engine.json; do
    [ -f "$root/$f" ] || fail "$f missing from the embedded kit"
done

ok "embedded kit matches the tracked source tree ($(cat "$T"/src-*.txt | grep -c .) files)"
