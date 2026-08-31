#!/usr/bin/env bash
set -uo pipefail
source "$SUBSTRATE_DIR/gate-lib.sh"

rc=0
REGISTRY="$REPO_ROOT/internal/gate/registry_gen.go"

[ -f "$REGISTRY" ] || {
    printf 'registry_gen.go not found at %s — generate with: just generate-registry\n' "$REGISTRY"
    exit 0
}

declare -A expected=()
while IFS='"' read -r _ name _ digest _; do
    [ -n "$digest" ] || continue
    expected["$name"]="$digest"
done < <(grep -E $'^\t"' "$REGISTRY")

for chk in "$SUBSTRATE_DIR"/checks.d/*.sh; do
    [ -f "$chk" ] || continue
    name=$(basename "$chk")
    actual=$(sha256sum "$chk" | cut -d' ' -f1)
    want="${expected[$name]:-}"
    if [ -z "$want" ]; then
        printf '%s not yet in registry — run: just generate-registry\n' "$name"
        rc=1
    elif [ "$actual" != "$want" ]; then
        printf '%s modified without re-generating registry — digest mismatch\n' "$name"
        printf '  actual:  %s\n' "$actual"
        printf '  registry: %s\n' "$want"
        printf '  Fix: just generate-registry\n'
        rc=1
    fi
done

declare -A native=()
read -ra native_list <<< "${SUBSTRATE_NATIVE_CHECKS:-}"
for n in ${native_list[@]+"${native_list[@]}"}; do native["$n"]=1; done

for name in "${!expected[@]}"; do
    [ -f "$SUBSTRATE_DIR/checks.d/$name" ] && continue
    # A native check has no bash body by design and the runner dispatches it
    # from the embedded registry, so a stale entry drops no coverage.
    if [ -n "${native[$name]:-}" ]; then
        printf '%s is native-only — stale registry entry; run: just generate-registry\n' "$name"
        continue
    fi
    printf '%s in registry but missing from disk — remove, or run: just generate-registry\n' "$name"
    rc=1
done

exit "$rc"
