#!/usr/bin/env bash
# Engine selection for ported hooks. Sourced, never executed.
# SUBSTRATE_ENGINE=auto|go|bash, SUBSTRATE_ENGINE_BIN=<path>,
# SUBSTRATE_ENGINE_SKIP=<comma-separated hook identities kept on bash>.

substrate_engine_exec() {
    local hook="$1"
    shift
    local mode="${SUBSTRATE_ENGINE:-auto}" bin="${SUBSTRATE_ENGINE_BIN:-}"
    case "$mode" in
        auto|go) ;;
        *) return 0 ;;
    esac
    case ",${SUBSTRATE_ENGINE_SKIP:-}," in
        *",$hook,"*) return 0 ;;
    esac
    if [ -z "$bin" ]; then
        bin=$(command -v substrate-engine 2>/dev/null) || bin=""
    fi
    if [ -z "$bin" ] || [ ! -x "$bin" ]; then
        # WHY: auto fails open to bash (doctor reports it), but an explicit
        # SUBSTRATE_ENGINE=go must never silently answer from the other leg —
        # that would make the A/B parity oracle vacuous.
        if [ "$mode" = go ]; then
            printf 'substrate engine: SUBSTRATE_ENGINE=go but no usable engine binary (%s)\n' \
                "${SUBSTRATE_ENGINE_BIN:-substrate-engine not on PATH}" >&2
            exit 2
        fi
        return 0
    fi
    [ -z "${SUBSTRATE_DIR:-}" ] || export SUBSTRATE_DIR
    [ -z "${REPO_ROOT:-}" ] || export REPO_ROOT
    exec "$bin" hook "$hook" "$@"
}
