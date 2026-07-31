#!/usr/bin/env bash
# Ruff-lints python-claimed .py files against the repo ruff.toml.
set -uo pipefail
# shellcheck source=../gate-lib.sh
source "$SUBSTRATE_DIR/gate-lib.sh"

files=()
while IFS= read -r f; do
    case "$f" in
        *.py) files+=("$f") ;;
    esac
done < <(profile_files python)

[ ${#files[@]} -gt 0 ] || exit 0

require_bin_ci ruff "profile toolchain — see profiles/python/profile.json" || exit 0

# only the user-global XDG layer dies here; in-repo hierarchical discovery gate:allow-comment
# (monorepo pyproject/ruff.toml) stays live — ~/.config is just the XDG
# default, so a void XDG_CONFIG_HOME kills both spellings.
out=$(
    export XDG_CONFIG_HOME=/substrate-nonexistent
    ruff check --no-cache --quiet "${files[@]}" 2>&1
)
rc=$?
case "$rc" in
    0) exit 0 ;;
    1) printf '%s\n' "$out"; exit 1 ;;
    *)
        printf '%s\n' "$out"
        die_infra "ruff failed (rc=$rc) — the gate cannot pass blind"
        ;;
esac
