#!/usr/bin/env bash
# Reuse an exact-state green receipt or run the deterministic gate before push.
set -uo pipefail

SUBSTRATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SUBSTRATE_DIR/.." && pwd)"
cd "$REPO_ROOT" || exit 2
# shellcheck source=./receipt-lib.sh
source "$SUBSTRATE_DIR/receipt-lib.sh"

if gate_receipt_matches || (substrate-engine maintenance repository-receipt-matches) >/dev/null 2>&1; then
    printf '[ok] push gate: exact-state receipt accepted\n'
    exit 0
fi
if ! substrate-engine gate; then
    printf 'push blocked: fix the failing gate checks first\n' >&2
    exit 2
fi
vcs=$(current_gate_vcs) || vcs=git
commit=$(current_gate_revision) || { printf 'push blocked: cannot resolve the checked revision\n' >&2; exit 2; }
if receipt=$(write_gate_receipt push "$commit" "$vcs"); then
    if [ "$(jq -r '.reusable' <<< "$receipt")" = true ]; then
        printf '[ok] push gate: green receipt recorded\n'
    else
        printf '[!] push gate: green, but this state is not reusable; this push may proceed\n' >&2
    fi
else
    printf '[!] push gate: green, but receipt recording failed; this push may proceed\n' >&2
fi
exit 0
