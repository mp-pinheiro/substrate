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
    env PATH="$path" SUBSTRATE_DIR="$KIT_ROOT/core" INVENTORY="$WORK/inventory" \
        "$KIT_ROOT/core/checks.d/20-duplication.sh" >"$output" 2>&1
}

run_check "$filtered_path" "$WORK/missing.out"
missing_rc=$?
if [ "$missing_rc" -ne 3 ] || ! grep -q "bunx is required but not installed" "$WORK/missing.out"; then
    cat "$WORK/missing.out"
    printf 'toolchain-parity-test: missing detector returned %d, want infrastructure exit 3\n' "$missing_rc" >&2
    exit 1
fi

mkdir -p "$WORK/wrong" "$WORK/exact"
printf '#!/usr/bin/env bash\nprintf "cpd 4.0.0\\n"\n' > "$WORK/wrong/jscpd"
printf '#!/usr/bin/env bash\nprintf "cpd 5.0.14\\n"\n' > "$WORK/exact/jscpd"
chmod +x "$WORK/wrong/jscpd" "$WORK/exact/jscpd"

run_check "$WORK/wrong:$filtered_path" "$WORK/wrong.out"
wrong_rc=$?
if [ "$wrong_rc" -ne 3 ] || ! grep -q "jscpd 5.0.14 is required" "$WORK/wrong.out"; then
    cat "$WORK/wrong.out"
    printf 'toolchain-parity-test: wrong detector version returned %d, want infrastructure exit 3\n' "$wrong_rc" >&2
    exit 1
fi

run_check "$WORK/exact:$filtered_path" "$WORK/exact.out"
exact_rc=$?
if [ "$exact_rc" -ne 0 ]; then
    cat "$WORK/exact.out"
    printf 'toolchain-parity-test: pinned detector returned %d, want 0\n' "$exact_rc" >&2
    exit 1
fi

printf 'toolchain-parity-test: missing, mismatched, and pinned detector scenarios green\n'
