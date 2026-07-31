#!/usr/bin/env bash
# Enforces import contracts (layers/forbidden) via lint-imports against the
# repo .importlinter; the shipped template is inactive until configured.
set -uo pipefail
# shellcheck source=../gate-lib.sh
source "$SUBSTRATE_DIR/gate-lib.sh"

if [ ! -f "$REPO_ROOT/.importlinter" ]; then
    warn "no .importlinter at repo root — import contracts inactive (substrate init installs a template)"
    exit 0
fi
if ! grep -Eq '^[[:space:]]*root_packages?[[:space:]]*=' "$REPO_ROOT/.importlinter"; then
    warn ".importlinter is the unconfigured template — uncomment root_packages and a contract to activate"
    exit 0
fi

require_bin_ci lint-imports "pipx install import-linter" || exit 0

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
