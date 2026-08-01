#!/usr/bin/env bash
# jj push alias target: a push seals work on the remote, so the vendored gate
# must be green first; then the caller's args pass through to jj git push.
set -uo pipefail

SUBSTRATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SUBSTRATE_DIR/.." && pwd)"
cd "$REPO_ROOT" || exit 2

if ! out=$("$SUBSTRATE_DIR/gate.sh" 2>&1); then
    printf '%s\n' "$out" | tail -25
    printf 'push blocked: fix the failing gate checks first\n' >&2
    exit 2
fi
exec jj git push "$@"
