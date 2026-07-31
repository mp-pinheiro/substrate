#!/usr/bin/env bash
# Enforces stylua formatting on claimed Lua files; config pinned to the repo
# .stylua.toml or the kit template so no user-global config decides verdicts.
set -uo pipefail
# shellcheck source=../gate-lib.sh
source "$SUBSTRATE_DIR/gate-lib.sh"

files=()
mapfile -t files < <(profile_files lua lua)

[ ${#files[@]} -gt 0 ] || exit 0

require_bin_ci stylua "prebuilt binary — https://github.com/JohnnyMorganz/StyLua/releases" || exit 0

st_config="$REPO_ROOT/.stylua.toml"
if [ ! -f "$st_config" ]; then
    st_config="$SUBSTRATE_DIR/profiles/lua/templates/stylua.toml"
    warn "no repo .stylua.toml — checking under the kit template"
fi
out=$(stylua --check --config-path "$st_config" "${files[@]}" 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then
    exit 0
fi
if [ "$rc" -eq 1 ]; then
    printf '%s\n' "$out"
    exit 1
fi
printf '%s\n' "$out"
die_infra "stylua failed to run (rc=$rc) — fix the invocation or the .stylua.toml"
