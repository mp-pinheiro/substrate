#!/usr/bin/env bash
# Firing oracle for 80-vendor-drift: mutate one vendored byte and the check
# must go red naming the drifted pair; restore and it must pass again.
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$KIT_ROOT" || exit 9

fail() { printf 'vendor-drift-test FAIL: %s\n' "$1" >&2; exit 1; }

export SUBSTRATE_DIR="$KIT_ROOT/.substrate"
export REPO_ROOT="$KIT_ROOT"
export CONFIG="$KIT_ROOT/substrate.json"
export LANGMAP="$KIT_ROOT/.substrate/langmap.json"
INVENTORY=$(mktemp)
export INVENTORY
git ls-files > "$INVENTORY"

target=".substrate/gate-lib.sh"
backup=$(mktemp)
cp "$target" "$backup"
trap 'cp "$backup" "$target"; rm -f "$backup" "$INVENTORY"' EXIT

checks.d/80-vendor-drift.sh >/dev/null || fail "clean tree does not pass vendor drift"

printf '\n' >> "$target"
out=$(checks.d/80-vendor-drift.sh)
rc=$?
[ "$rc" -ne 0 ] || fail "check stayed green with a mutated vendored file"
printf '%s' "$out" | grep -q 'gate-lib.sh' || fail "red run does not name the drifted file"

cp "$backup" "$target"
checks.d/80-vendor-drift.sh >/dev/null || fail "restored tree does not pass again"

printf 'vendor-drift-test: fires on mutation, green on restore\n'
