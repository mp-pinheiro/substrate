#!/usr/bin/env bash
# Dependency boundaries for claimed .ts files via dependency-cruiser, pinned to
# the repo's .dependency-cruiser.cjs (installed as a template by init).
set -uo pipefail
# shellcheck source=../gate-lib.sh
source "$SUBSTRATE_DIR/gate-lib.sh"

if [ ! -f "$REPO_ROOT/.dependency-cruiser.cjs" ]; then
    warn "no .dependency-cruiser.cjs — dependency-cruiser inactive (substrate init installs a template)"
    exit 0
fi

files=()
mapfile -t files < <(profile_files typescript typescript)

[ ${#files[@]} -gt 0 ] || exit 0

# global depcruise, pinned by the ci install line (bunx would re-resolve gate:allow-comment
# the latest release on every run — version drift in the verdict path).
require_bin_ci depcruise "profile toolchain — see profiles/typescript/profile.json" || exit 0

errf=$(mktemp)
out=$(depcruise --config "$REPO_ROOT/.dependency-cruiser.cjs" --output-type json "${files[@]}" 2>"$errf")
rc=$?
err=$(cat "$errf")
rm -f "$errf"

if [ "$rc" -ne 0 ]; then
    printf '%s\n' "${err:-$out}"
    die_infra "dependency-cruiser failed (rc=$rc, not findings) — fix .dependency-cruiser.cjs or the invocation"
fi

errors=$(jq -er '.summary.error' <<< "$out" 2>/dev/null) \
    || die_infra "dependency-cruiser emitted unparseable JSON — cannot pass blind"

warns=$(jq -r '.summary.warn // 0' <<< "$out")
if [ "$warns" -gt 0 ]; then
    warn "$warns warn-severity dependency violations (non-blocking):"
    jq -r '.summary.violations[] | select(.rule.severity != "error")
        | "  \(.from) -> \(.to) — \(.rule.name)"' <<< "$out"
fi

[ "$errors" -eq 0 ] && exit 0

jq -r '.summary.violations[] | select(.rule.severity == "error")
    | "\(.from) -> \(.to) — \(.rule.name) — break the dependency (rules and rationale live in .dependency-cruiser.cjs)"' <<< "$out"
exit 1
