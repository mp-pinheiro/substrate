#!/usr/bin/env bash
# Typechecks the kit's own TS (the omp harness mirror). Two modes, printed:
# the installed @oh-my-pi/pi-coding-agent types when resolvable (true API
# conformance), else the recorded surface in types/pi-surface.d.ts — that
# weaker green means "internally consistent", not "conforms to omp".
set -uo pipefail
# shellcheck source=../../../core/gate-lib.sh
source "$SUBSTRATE_DIR/gate-lib.sh"

files=()
mapfile -t files < <(profile_files kit-ts)
[ ${#files[@]} -gt 0 ] || exit 0

require_bin_ci bunx "bun runtime — https://bun.sh" || exit 0

kit_ts_dir="$REPO_ROOT/substrate-profiles/kit-ts"
ambient="$kit_ts_dir/types/bun-ambient.d.ts"
surface="$kit_ts_dir/types/pi-surface.d.ts"
[ -f "$ambient" ] || die_infra "bun ambient decl missing: $ambient"
filtered=()
for file in "${files[@]}"; do
    case "$REPO_ROOT/$file" in
        "$ambient"|"$surface") ;;
        *) filtered+=("$file") ;;
    esac
done
files=("${filtered[@]}")

sdk_types="${BUN_INSTALL:-$HOME/.bun}/install/global/node_modules/@oh-my-pi/pi-coding-agent/dist/types/index.d.ts"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# run_tsc <label> <paths_json> [extra decl...] — 0 clean, 1 findings, 2 infra
run_tsc() {
    local label="$1" paths="$2" out rc f
    shift 2
    jq -n --argjson paths "$paths" '{
        compilerOptions: {
            noEmit: true, strict: true, target: "esnext", module: "esnext",
            moduleResolution: "bundler", skipLibCheck: true, types: [],
            paths: $paths
        }
    }' > "$tmp/tsconfig.json"
    local abs_files=()
    for f in "$ambient" "$@" "${files[@]}"; do
        case "$f" in
            /*) abs_files+=("$f") ;;
            *) abs_files+=("$REPO_ROOT/$f") ;;
        esac
    done
    jq --args '.files = $ARGS.positional' "${abs_files[@]}" < "$tmp/tsconfig.json" > "$tmp/t2.json" \
        && mv "$tmp/t2.json" "$tmp/tsconfig.json"
    out=$(bunx --bun -p typescript@6.0.3 tsc -p "$tmp/tsconfig.json" 2>&1)
    rc=$?
    [ "$rc" -eq 0 ] && return 0
    printf '%s\n' "$out"
    if printf '%s' "$out" | grep -q 'error TS'; then
        printf 'kit-tsc (%s): findings above\n' "$label"
        return 1
    fi
    die_infra "tsc ($label) failed (rc=$rc) without diagnostics — the gate cannot pass blind"
}

if [ -f "$sdk_types" ]; then
    printf 'kit-tsc: checking against installed omp SDK types\n'
    run_tsc "installed SDK" "$(jq -n --arg p "$sdk_types" '{"@oh-my-pi/pi-coding-agent": [$p]}')" || exit 1
    if ! run_tsc "recorded surface" '{}' "$surface"; then
        printf 'recorded surface disagrees with the installed SDK — refresh %s\n' "substrate-profiles/kit-ts/types/pi-surface.d.ts"
        exit 1
    fi
    exit 0
fi
warn "omp SDK not resolvable — recorded-surface mode is best-effort, NOT API conformance"
run_tsc "recorded surface" '{}' "$surface" || exit 1
exit 0
