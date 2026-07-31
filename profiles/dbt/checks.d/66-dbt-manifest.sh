#!/usr/bin/env bash
# Manifest discipline: incremental models must declare a unique_key, and the
# undocumented-model count is ratcheted. jq-only — no dbt runtime needed.
set -uo pipefail
# shellcheck source=../gate-lib.sh
source "$SUBSTRATE_DIR/gate-lib.sh"

manifest="$REPO_ROOT/target/manifest.json"
if [ ! -f "$manifest" ]; then
    warn "no target/manifest.json — manifest discipline inactive (run: dbt parse)"
    exit 0
fi
jq -e . "$manifest" >/dev/null 2>&1 || die_infra "target/manifest.json is not valid JSON — regenerate with dbt parse"

findings=$(jq -r '
    .nodes // {} | to_entries[]
    | select(.value.resource_type == "model")
    | select((.value.config.materialized // "") == "incremental")
    | select(
        (.value.config.unique_key // "")
        | (if type == "array" then length else (tostring | length) end) == 0
      )
    | "\(.value.original_file_path // .key) — incremental models must declare unique_key (\(.key)) — set config.unique_key"
' "$manifest") || die_infra "jq failed reading $manifest"

undocumented=$(jq -r '
    [.nodes // {} | to_entries[]
     | select(.value.resource_type == "model")
     | select(((.value.description // "") | length) == 0)]
    | length
' "$manifest") || die_infra "jq failed reading $manifest"
metric "dbt_undocumented" "$undocumented"

if [ -n "$findings" ]; then
    printf '%s\n' "$findings"
    exit 1
fi
exit 0
