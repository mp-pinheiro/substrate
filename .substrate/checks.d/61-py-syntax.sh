#!/usr/bin/env bash
# Byte-compiles every python-claimed file (including extensionless
# shebang scripts); syntax errors are findings.
set -uo pipefail
# shellcheck source=../gate-lib.sh
source "$SUBSTRATE_DIR/gate-lib.sh"

files=()
mapfile -t files < <(profile_files python)

[ ${#files[@]} -gt 0 ] || exit 0

require_bin_ci python3 "profile toolchain — see profiles/python/profile.json" || exit 0

cache=$(mktemp -d)
export PYTHONPYCACHEPREFIX="$cache"
out=$(python3 -m py_compile "${files[@]}" 2>&1)
rc=$?
rm -rf "$cache"
case "$rc" in
    0) exit 0 ;;
    1) printf '%s\n' "$out"; exit 1 ;;
    *)
        printf '%s\n' "$out"
        die_infra "py_compile failed (rc=$rc) — the gate cannot pass blind"
        ;;
esac
