#!/usr/bin/env bash
# Per-file comment ratchet for write-time hooks.
# Usage: comment-ratchet.sh <file>
# Exit 0 at-or-below the grandfathered baseline metric; exit 1 with the report
# otherwise — including when the detector itself breaks (infra must not read as pass).
set -uo pipefail

SUBSTRATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SUBSTRATE_DIR/.." && pwd)"
# shellcheck source=engine-shim.sh
source "$SUBSTRATE_DIR/engine-shim.sh"
substrate_engine_exec comment-ratchet "$@"
cd "$REPO_ROOT" || exit 1
export CONFIG="$REPO_ROOT/substrate.json"
export LANGMAP="$SUBSTRATE_DIR/langmap.json"
BASELINE="$REPO_ROOT/substrate-baseline.json"

file="${1:-}"
[ -n "$file" ] || exit 0
case "$file" in
    "$REPO_ROOT"/*) file="${file#"$REPO_ROOT"/}" ;;
esac
[ -f "$file" ] || exit 0

out=$("$SUBSTRATE_DIR/check-comments.sh" "$file")
rc=$?
if [ "$rc" -ge 2 ]; then
    printf '%s\n' "$out"
    printf 'comment ratchet: detector infrastructure failed (rc=%d) — fix it before editing\n' "$rc"
    exit 1
fi

count=$(grep -cE '^[^ ]+:[0-9]+: ' <<< "$out") || count=0

allowed=0
if [ -f "$BASELINE" ]; then
    allowed=$(jq -r --arg k "comments:$file" '.metrics[$k] // 0' "$BASELINE" 2>/dev/null) || allowed=0
fi

if ! [[ "$allowed" =~ ^[0-9]+$ ]]; then
    printf 'comment ratchet: baseline metric comments:%s is not a whole number — fix substrate-baseline.json\n' "$file"
    exit 1
fi

if [ "$count" -gt "$allowed" ]; then
    printf '%s\n' "$out"
    printf 'comment ratchet: %s has %d finding(s), grandfathered allowance is %d.\n' "$file" "$count" "$allowed"
    exit 1
fi
exit 0
