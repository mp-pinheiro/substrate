#!/usr/bin/env bash
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

filtered="$WORK/filtered"
mkdir -p "$filtered"
filtered_path=""
IFS=: read -r -a path_parts <<< "$PATH"
for dir in "${path_parts[@]}"; do
    if [ -x "$dir/jscpd" ] || [ -x "$dir/bunx" ]; then
        for file in "$dir"/*; do
            name=$(basename "$file")
            [ "$name" = jscpd ] && continue
            [ "$name" = bunx ] && continue
            [ -x "$file" ] && [ ! -e "$filtered/$name" ] && ln -s "$file" "$filtered/$name"
        done
        continue
    fi
    filtered_path="${filtered_path:+$filtered_path:}$dir"
done
filtered_path="$filtered:$filtered_path"
touch "$WORK/inventory"

run_check() {
    local path="$1" output="$2"
    env PATH="$path" SUBSTRATE_DIR="$KIT_ROOT/core" INVENTORY="$WORK/inventory" METRICS="$WORK/metrics" \
        "$KIT_ROOT/core/checks.d/20-duplication.sh" >"$output" 2>&1
}

run_check "$filtered_path" "$WORK/missing.out"
missing_rc=$?
if [ "$missing_rc" -ne 3 ] || ! grep -q "bunx is required but not installed" "$WORK/missing.out"; then
    cat "$WORK/missing.out"
    printf 'toolchain-parity-test: missing detector returned %d, want infrastructure exit 3\n' "$missing_rc" >&2
    exit 1
fi

mkdir -p "$WORK/fallback" "$WORK/exact"
printf '#!/usr/bin/env bash\nprintf "cpd 4.0.0\\n"\n' > "$WORK/fallback/jscpd"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/fallback/bunx"
printf '#!/usr/bin/env bash\nprintf "ast-grep 0.44.0\\n"\n' > "$WORK/fallback/ast-grep"
printf '#!/usr/bin/env bash\nprintf "cpd 5.0.14\\n"\n' > "$WORK/exact/jscpd"
chmod +x "$WORK/fallback/jscpd" "$WORK/fallback/bunx" "$WORK/fallback/ast-grep" "$WORK/exact/jscpd"

run_check "$WORK/fallback:$filtered_path" "$WORK/fallback.out"
fallback_rc=$?
if [ "$fallback_rc" -ne 0 ]; then
    cat "$WORK/fallback.out"
    printf 'toolchain-parity-test: pinned fallback returned %d, want 0\n' "$fallback_rc" >&2
    exit 1
fi

run_check "$WORK/exact:$filtered_path" "$WORK/exact.out"
exact_rc=$?
if [ "$exact_rc" -ne 0 ]; then
    cat "$WORK/exact.out"
    printf 'toolchain-parity-test: pinned detector returned %d, want 0\n' "$exact_rc" >&2
    exit 1
fi

ast_resolution=$(env PATH="$WORK/fallback:$filtered_path" SUBSTRATE_DIR="$KIT_ROOT/core" \
    bash -c 'source "$SUBSTRATE_DIR/gate-lib.sh"; SG=(); resolve_sg; printf "%s\n" "${SG[*]}"')
[ "$ast_resolution" = "bunx --yes @ast-grep/cli@0.45.0" ] \
    || { printf 'toolchain-parity-test: wrong ast-grep resolution: %s\n' "$ast_resolution" >&2; exit 1; }

legacy_out=$(env PATH="$filtered_path" SUBSTRATE_DIR="$KIT_ROOT/core" \
    bash -c 'source "$SUBSTRATE_DIR/gate-lib.sh"; require_bin_ci legacy-detector "install legacy detector"' 2>&1)
legacy_rc=$?
if [ "$legacy_rc" -ne 3 ] || [[ "$legacy_out" != *"legacy-detector is required but not installed"* ]]; then
    printf '%s\n' "$legacy_out"
    printf 'toolchain-parity-test: legacy detector alias returned %d, want infrastructure exit 3\n' "$legacy_rc" >&2
    exit 1
fi

printf 'toolchain-parity-test: missing, mismatched, and pinned detector scenarios green\n'
