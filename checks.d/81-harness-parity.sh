#!/usr/bin/env bash
# Dual-harness parity (design rule 6): every Claude hook names a mirror in the
# omp extension — a hook without one silently drops a harness, which is how
# the push gate went missing. Arg 1 overrides the omp source (firing test).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2

OMP_SRC="${1:-core/omp/substrate-quality.ts}"

rc=0
for f in core/hooks/*.sh; do
    [ -f "$f" ] || continue
    b=$(basename "$f")
    if ! grep -q "mirrors: $b" "$OMP_SRC"; then
        printf '%s has no omp mirror — add the handler and mark it "// mirrors: %s"\n' "$b" "$b"
        rc=1
    fi
done
exit "$rc"
