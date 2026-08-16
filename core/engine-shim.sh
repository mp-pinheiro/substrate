#!/usr/bin/env bash
set -uo pipefail

_substrate_engine_bin() {
    if [ -n "${SUBSTRATE_ENGINE_BIN:-}" ] && [ -x "$SUBSTRATE_ENGINE_BIN" ]; then
        printf '%s\n' "$SUBSTRATE_ENGINE_BIN"
    elif command -v substrate-engine >/dev/null 2>&1; then
        command -v substrate-engine
    else
        return 1
    fi
}

substrate_engine_supports() {
    local engine
    engine=$(_substrate_engine_bin) || return 1
    [ -x "$engine" ] || return 1
    local caps
    if ! caps=$("$engine" capabilities 2>/dev/null); then
        return 2
    fi
    local wanted
    for wanted in "$@"; do
        local found=0 verb
        for verb in $caps; do
            [ "$verb" = "$wanted" ] && { found=1; break; }
        done
        [ "$found" -eq 1 ] || return 1
    done
    return 0
}

substrate_engine_exec() {
    local engine
    engine=$(_substrate_engine_bin) || return 1
    exec "$engine" hook "$@"
}

# _substrate_engine_delegate <capability> <fallback-fn> <verb-words...> -- [args...]
# Delegates when the engine supports <capability>; never exec's (callers capture stdout).
_substrate_engine_delegate() {
    local capability="$1" fallback="$2"
    shift 2
    local verb=()
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
        verb+=("$1")
        shift
    done
    [ "$#" -eq 0 ] || shift
    local mode=${SUBSTRATE_ENGINE:-auto}
    local engine
    if [ "$mode" != bash ] && engine=$(_substrate_engine_bin) \
        && substrate_engine_supports "$capability"; then
        "$engine" "${verb[@]}" "$@"
        return
    fi
    if [ "$mode" = go ]; then
        printf 'substrate: engine required for %s but unavailable\n' "$capability" >&2
        return 3
    fi
    "$fallback" "$@"
}
