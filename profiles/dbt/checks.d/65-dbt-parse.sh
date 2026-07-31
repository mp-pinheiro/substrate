#!/usr/bin/env bash
# Parses the dbt project against a vendored duckdb profile so refs and
# configs are validated without a warehouse connection.
set -uo pipefail
# shellcheck source=../gate-lib.sh
source "$SUBSTRATE_DIR/gate-lib.sh"

if [ ! -f "$REPO_ROOT/dbt_project.yml" ]; then
    warn "no dbt_project.yml — dbt profile inactive; drop the profile from substrate.json or add a dbt project"
    exit 0
fi

require_bin_ci dbt "profile toolchain — see profiles/dbt/profile.json" || exit 0

export DBT_PROFILES_DIR="$SUBSTRATE_DIR/profiles/dbt/profiles"
out=$(dbt parse --no-version-check 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then
    exit 0
fi
if [ "$rc" -eq 1 ] || grep -qE 'Compilation Error|Parsing Error' <<< "$out"; then
    printf '%s\n' "$out"
    exit 1
fi
printf '%s\n' "$out"
die_infra "dbt crashed (rc=$rc) — fix the dbt installation or the vendored duckdb profile"
