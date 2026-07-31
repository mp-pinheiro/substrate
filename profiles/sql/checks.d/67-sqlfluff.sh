#!/usr/bin/env bash
# Lints claimed SQL files with sqlfluff under the repo .sqlfluff config.
# Violations are findings; sqlfluff user errors fail the gate closed.
set -uo pipefail
# shellcheck source=../gate-lib.sh
source "$SUBSTRATE_DIR/gate-lib.sh"

files=()
mapfile -t files < <(profile_files sql)

[ ${#files[@]} -gt 0 ] || exit 0

require_bin_ci sqlfluff "profile toolchain — see profiles/sql/profile.json" || exit 0

sf_config="$REPO_ROOT/.sqlfluff"
if [ ! -f "$sf_config" ]; then
    sf_config="$SUBSTRATE_DIR/profiles/sql/templates/sqlfluff.cfg"
    warn "no repo .sqlfluff — linting under the kit template"
fi
# --ignore-local-config drops the user layer AND nested in-repo .sqlfluff gate:allow-comment
# files: only the pinned --config applies. Per-dir sqlfluff configs are
# unsupported — same stance as luacheck.
out=$(sqlfluff lint --nocolor --ignore-local-config --config "$sf_config" "${files[@]}" 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then
    exit 0
fi
if [ "$rc" -eq 1 ]; then
    [ -n "$out" ] || die_infra "sqlfluff exited 1 with no report — cannot pass blind"
    printf '%s\n' "$out"
    exit 1
fi
printf '%s\n' "$out"
die_infra "sqlfluff failed (rc=$rc) — fix the .sqlfluff config or the invocation"
