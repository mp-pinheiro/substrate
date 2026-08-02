#!/usr/bin/env bash
# jj push alias target: validate an exact receipt or run the gate, then pass
# the caller's arguments through to jj git push. Invocation remains explicit.
set -uo pipefail

SUBSTRATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SUBSTRATE_DIR/.." && pwd)"
cd "$REPO_ROOT" || exit 2

if ! "$SUBSTRATE_DIR/push-gate.sh"; then
    exit 2
fi
exec jj git push "$@"
