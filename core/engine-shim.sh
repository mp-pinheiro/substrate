#!/usr/bin/env bash
set -uo pipefail

substrate_engine_supports() {
    local wanted verb
    local engine=""
    if [ -n "${SUBSTRATE_ENGINE_BIN:-}" ] && [ -x "$SUBSTRATE_ENGINE_BIN" ]; then
        engine="$SUBSTRATE_ENGINE_BIN"
    elif engine=$(command -v substrate-engine 2>/dev/null) && [ -n "$engine" ]; then
        :
    else
        return 1
    fi
    [ -x "$engine" ] || return 1
    local caps
    if ! caps=$("$engine" capabilities 2>/dev/null); then
        return 2
    fi
    for wanted in "$@"; do
        local found=0
        for verb in $caps; do
            [ "$verb" = "$wanted" ] && { found=1; break; }
        done
        [ "$found" -eq 1 ] || return 1
    done
    return 0
}
