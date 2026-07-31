#!/usr/bin/env bash
# Dead-code gate: vulture 100%-confidence findings fail outright; everything
# at >=80% confidence feeds the ratcheted dead_code metric.
set -uo pipefail
# shellcheck source=../gate-lib.sh
source "$SUBSTRATE_DIR/gate-lib.sh"

files=()
mapfile -t files < <(profile_files_ext python .py)

if [ ${#files[@]} -eq 0 ]; then
    metric "dead_code" 0
    exit 0
fi

require_bin_ci vulture "pipx install vulture" || exit 0

out=$(vulture --min-confidence 80 "${files[@]}" 2>&1)
rc=$?
case "$rc" in
    0)
        metric "dead_code" 0
        exit 0
        ;;
    1)
        printf '%s\n' "$out"
        exit 1
        ;;
    3) ;;
    *)
        printf '%s\n' "$out"
        die_infra "vulture failed (rc=$rc) — the gate cannot pass blind"
        ;;
esac

count=$(grep -c '% confidence)$' <<< "$out")
metric "dead_code" "$count"

sure=$(grep -F '(100% confidence)' <<< "$out")
if [ -n "$sure" ]; then
    printf '%s\n' "$sure"
    printf 'delete the dead code above (or add an intentional-use reference) — vulture is 100%%-certain\n'
    exit 1
fi
exit 0
