#!/usr/bin/env bash
set -uo pipefail
source "$SUBSTRATE_DIR/gate-lib.sh"

[ -n "$(profile_files python | head -n 1)" ] || exit 0
[ -f "$REPO_ROOT/.importlinter" ] || exit 0
grep -Eq '^[[:space:]]*root_packages?[[:space:]]*=' "$REPO_ROOT/.importlinter" || exit 0

require_bin lint-imports "pipx install import-linter"

out=$(lint-imports --no-cache --config "$REPO_ROOT/.importlinter" 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then
    exit 0
fi
if [ "$rc" -eq 1 ] && grep -q 'Broken contracts' <<< "$out"; then
    printf '%s\n' "$out"
    exit 1
fi
printf '%s\n' "$out"
die_infra "lint-imports failed (rc=$rc, no contract report) — fix .importlinter or the package layout"
