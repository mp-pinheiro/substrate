#!/usr/bin/env bash
# Type/compile checks for claimed .svelte files via a globally installed
# svelte-check (pinned by the ci install line; needs typescript@6 + svelte).
set -uo pipefail
# shellcheck source=../gate-lib.sh
source "$SUBSTRATE_DIR/gate-lib.sh"

files=()
mapfile -t files < <(profile_files svelte "" scan_target)

[ ${#files[@]} -gt 0 ] || exit 0

require_bin_ci svelte-check "profile toolchain — see profiles/svelte/profile.json" || exit 0

# --no-tsconfig pins the verdict: without it svelte-check walks UP from gate:allow-comment
# the workspace for the nearest tsconfig, so a file outside the repo could
# change the result. Repo svelte.config.js is still auto-loaded.
out=$(svelte-check --workspace "$REPO_ROOT" --no-tsconfig --output machine 2>&1)
rc=$?

grep -q ' COMPLETED ' <<< "$out" \
    || { printf '%s\n' "$out"; die_infra "svelte-check did not complete (rc=$rc) — cannot pass blind"; }

FOUND=0
while IFS= read -r line; do
    if [[ "$line" =~ ^[0-9]+\ (ERROR|WARNING)\ \"([^\"]+)\"\ ([0-9]+):[0-9]+\ \"(.*)\"$ ]]; then
        sev="${BASH_REMATCH[1]}"
        f="${BASH_REMATCH[2]}"
        lno="${BASH_REMATCH[3]}"
        msg="${BASH_REMATCH[4]}"
        scan_target "$f" || continue
        if [ "$sev" = "ERROR" ]; then
            printf '%s:%s — %s — fix the component (svelte-check)\n' "$f" "$lno" "$msg"
            FOUND=1
        else
            warn "$f:$lno — $msg (svelte-check warning, non-blocking)"
        fi
    fi
done <<< "$out"

exit "$FOUND"
