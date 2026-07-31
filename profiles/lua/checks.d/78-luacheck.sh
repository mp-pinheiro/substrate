#!/usr/bin/env bash
# Lints claimed Lua files with luacheck; every warning or error is a finding.
set -uo pipefail
# shellcheck source=../gate-lib.sh
source "$SUBSTRATE_DIR/gate-lib.sh"

files=()
mapfile -t files < <(profile_files lua lua)

[ ${#files[@]} -gt 0 ] || exit 0

require_bin_ci luacheck "profile toolchain — see profiles/lua/profile.json" || exit 0

if [ -f "$REPO_ROOT/.luacheckrc" ]; then
    lc_args=(--config "$REPO_ROOT/.luacheckrc")
else
    lc_args=(--no-config --no-default-config)
fi
out=$(luacheck --no-color "${lc_args[@]}" "${files[@]}" 2>&1)
rc=$?
case "$rc" in
    0) exit 0 ;;
    1 | 2)
        printf '%s\n' "$out"
        exit 1
        ;;
    *)
        printf '%s\n' "$out"
        die_infra "luacheck failed to run (rc=$rc)"
        ;;
esac
