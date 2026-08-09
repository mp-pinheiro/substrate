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
