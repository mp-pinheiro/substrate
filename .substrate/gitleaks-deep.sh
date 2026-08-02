#!/usr/bin/env bash
# Full reachable-history secret scan, cached only for an exact refs/tool/config state.
set -uo pipefail

SUBSTRATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SUBSTRATE_DIR/.." && pwd)"
cd "$REPO_ROOT" || exit 2
# shellcheck source=./gate-lib.sh
source "$SUBSTRATE_DIR/gate-lib.sh"
# shellcheck source=./gitleaks-lib.sh
source "$SUBSTRATE_DIR/gitleaks-lib.sh"

inside=$(git rev-parse --is-inside-work-tree 2>/dev/null) || die_infra "deep Gitleaks scan requires a Git worktree"
[ "$inside" = true ] || die_infra "deep Gitleaks scan requires a Git worktree"
have gitleaks || die_infra "gitleaks is required for the deep scan"
use_cache=1
print_key=0
case "${1:-}" in
    "") ;;
    --no-cache) use_cache=0 ;;
    --print-key) print_key=1 ;;
    *) printf 'usage: %s [--no-cache|--print-key]\n' "$0" >&2; exit 2 ;;
esac

key=$(gitleaks_deep_key) || die_infra "cannot compute deep-scan cache key"
if [ "$print_key" -eq 1 ]; then
    printf '%s\n' "$key"
    exit 0
fi
git_dir=$(git rev-parse --git-common-dir) || die_infra "cannot resolve Git metadata"
case "$git_dir" in
    /*) ;;
    *) git_dir="$REPO_ROOT/$git_dir" ;;
esac
cache_dir="$git_dir/substrate"
cache="$cache_dir/gitleaks-deep.json"
if [ "$use_cache" -eq 1 ] && [ -f "$cache" ] \
    && jq -e --arg key "$key" '.status == "passed" and .key == $key' "$cache" >/dev/null 2>&1; then
    success "gitleaks deep scan: exact-state cache hit"
    exit 0
fi

report=$(mktemp)
trap 'rm -f "$report"' EXIT
gitleaks git --no-banner --redact --verbose --log-opts=--all >"$report" 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
    rm -f "$cache"
    cat "$report" >&2
    if [ "$rc" -eq 1 ]; then
        warn "gitleaks deep scan found potential secrets"
        exit 1
    fi
    die_infra "gitleaks deep scan failed (rc=$rc)"
fi
mkdir -p "$cache_dir" || die_infra "cannot create deep-scan cache directory"
receipt=$(jq -cn --arg key "$key" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg version "$(gitleaks version | tr -d '\r\n')" \
    --arg configHash "$(gitleaks_config_hash)" \
    '{key:$key,status:"passed",at:$at,version:$version,configHash:$configHash}') \
    || die_infra "cannot serialize deep-scan receipt"
staged=$(mktemp "$cache_dir/gitleaks-deep.json.XXXXXX") \
    || die_infra "cannot stage deep-scan receipt"
if printf '%s\n' "$receipt" > "$staged" && mv -f "$staged" "$cache"; then
    success "gitleaks deep scan: full reachable history passed"
    exit 0
fi
rm -f "$staged"
die_infra "cannot write deep-scan receipt"
