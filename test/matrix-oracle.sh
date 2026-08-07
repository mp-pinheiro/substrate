#!/usr/bin/env bash
# Asserts one profile's matrix run rejected a named fixture; exit 3 = toolchain unusable.
set -uo pipefail

[ "$#" -eq 2 ] || { printf 'usage: %s <profile> <needle>\n' "$0" >&2; exit 2; }

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$KIT_ROOT" || exit 2
export CI=1

out=$(bash test/matrix.sh "$1" 2>&1)
rc=$?
if [ "$rc" -eq 3 ]; then
    printf '%s\n' "$out" >&2
    exit 3
fi
if printf '%s' "$out" | grep -q "$2"; then
    exit 0
fi
printf '%s\n' "$out" >&2
printf 'matrix-oracle: %s did not report: %s\n' "$1" "$2" >&2
exit 1
