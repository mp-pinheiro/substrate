#!/usr/bin/env bash

maintenance_sync_external_units() {
    local transaction_receipt="$1" stable_receipt="$2" runtime_status=passed harness_status=skipped
    local fail_phase=""
    [ "${SUBSTRATE_MAINTENANCE_TESTING:-}" != 1 ] \
        || fail_phase=${SUBSTRATE_MAINTENANCE_FAIL_PHASE:-}
    if [ "$fail_phase" = runtime ]; then runtime_status=failed; else sync_repo_runtime || runtime_status=failed; fi
    maintenance_update_receipt "$transaction_receipt" "$stable_receipt" \
        ".repoRuntime.status=\"$runtime_status\"" || return 1
    if [ "$MAINTENANCE_REPO_ONLY" -eq 0 ] && [ "${SUBSTRATE_NO_USER_HARNESS:-}" != 1 ]; then
        harness_status=passed
        if [ "$fail_phase" = harness ]; then harness_status=failed; else maintenance_sync_user_locked || harness_status=failed; fi
    fi
    maintenance_update_receipt "$transaction_receipt" "$stable_receipt" \
        ".userHarness.status=\"$harness_status\"" || return 1
    [ "$runtime_status" = passed ] && { [ "$harness_status" = passed ] || [ "$harness_status" = skipped ]; }
}

maintenance_sync_user_locked() {
    local state_root="$HOME/.local/state/substrate" lock receipt rc=0 value
    user_path_safe "$state_root" "user harness state" || return 1
    mkdir -p "$state_root" || return 1
    lock="$state_root/harness.lock"
    mkdir "$lock" 2>/dev/null || { warn "another user harness synchronization is active"; return 1; }
    if ! sync_user_harness; then
        rc=1
    fi
    receipt="$state_root/harness-receipt.json"
    value=$(jq -cn --arg status "$([ "$rc" -eq 0 ] && printf passed || printf incomplete)" \
        --arg engineVersion "$(cat "$KIT_ROOT/VERSION")" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{status:$status,engineVersion:$engineVersion,at:$at}') || rc=1
    maintenance_write_json "$receipt" "$value" || rc=1
    rmdir "$lock" 2>/dev/null || rc=1
    return "$rc"
}

maintenance_finish_output() {
    local receipt="$1" status commit
    status=$(jq -r '.repository.status' "$receipt")
    commit=$(jq -r '.repository.commit // empty' "$receipt")
    if [ "$MAINTENANCE_JSON" -eq 1 ]; then
        cat "$receipt"
    elif [ "$status" = committed ] && [ "$(jq '.repository.changedPaths | length' "$receipt")" -eq 0 ]; then
        printf 'repository: unchanged at %s\n' "${commit:0:12}"
        printf 'repo runtime: %s\n' "$(jq -r '.repoRuntime.status' "$receipt")"
        printf 'user harness: %s\n' "$(jq -r '.userHarness.status' "$receipt")"
        printf 'push: not performed\n'
    elif [ "$status" = committed ]; then
        printf 'repository: committed %s\n' "${commit:0:12}"
        printf 'repo runtime: %s\n' "$(jq -r '.repoRuntime.status' "$receipt")"
        printf 'user harness: %s\n' "$(jq -r '.userHarness.status' "$receipt")"
        printf 'push: not performed\n'
    else
        printf 'repository: %s (checkpoint with --checkpoint)\n' "$status"
        printf 'push: not performed\n'
    fi
}
