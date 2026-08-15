#!/usr/bin/env bash
maintenance_run() {
    local dir root bin rc
    dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    root="$(cd "$dir/.." && pwd)"
    bin="${SUBSTRATE_ENGINE_BIN:-$root/build/substrate-engine}"
    SUBSTRATE_KIT_ROOT="$root" "$bin" maintenance "$@"
    rc=$?
    if [ "$rc" -eq 0 ] && declare -F sync_repo_runtime >/dev/null 2>&1; then
        sync_repo_runtime || rc=1
    fi
    if [ "$rc" -eq 0 ] && [ "${SUBSTRATE_NO_USER_HARNESS:-}" != "1" ] && declare -F install_user_harness >/dev/null 2>&1; then
        install_user_harness || rc=1
    fi
    return "$rc"
}
