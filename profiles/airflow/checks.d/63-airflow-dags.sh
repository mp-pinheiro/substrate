#!/usr/bin/env bash
# Validates DAG files under dags/: syntax always; deep import, DAG-presence,
# and dag_id-uniqueness checks when apache-airflow is importable (CI enforces).
set -uo pipefail
# shellcheck source=../gate-lib.sh
source "$SUBSTRATE_DIR/gate-lib.sh"

if [ ! -d "$REPO_ROOT/dags" ]; then
    warn "no dags/ directory — airflow check inactive (drop the airflow profile if unused)"
    exit 0
fi

require_bin_ci python3 "profile toolchain — see profiles/airflow/profile.json" || exit 0

out=$(python3 "$SUBSTRATE_DIR/profiles/airflow/helpers/dag_integrity.py" dags 2>&1)
rc=$?
case "$rc" in
    0)
        [ -n "$out" ] && printf '%s\n' "$out"
        exit 0
        ;;
    1) printf '%s\n' "$out"; exit 1 ;;
    *)
        printf '%s\n' "$out"
        die_infra "dag integrity helper failed (rc=$rc) — the gate cannot pass blind"
        ;;
esac
