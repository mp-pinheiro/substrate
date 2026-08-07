#!/usr/bin/env bash
# Engine selection for ported hooks. Sourced, never executed.
# SUBSTRATE_ENGINE=auto|go|bash, SUBSTRATE_ENGINE_BIN=<path>,
# SUBSTRATE_ENGINE_SKIP=<comma-separated hook identities kept on bash>.

_substrate_engine_resolve() {
    local hook="$1"
    local mode="${SUBSTRATE_ENGINE:-auto}" bin="${SUBSTRATE_ENGINE_BIN:-}"
    case "$mode" in
        auto|go) ;;
        *) return 1 ;;
    esac
    case ",${SUBSTRATE_ENGINE_SKIP:-}," in
        *",$hook,"*) return 1 ;;
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
            return 2
        fi
        return 1
    fi
    printf '%s\n' "$bin"
}

substrate_engine_exec() {
    local hook="$1"
    shift
    local bin
    bin=$(_substrate_engine_resolve "$hook")
    case $? in
        0) ;;
        2) exit 2 ;;
        *) return 0 ;;
    esac
    [ -z "${SUBSTRATE_DIR:-}" ] || export SUBSTRATE_DIR
    [ -z "${REPO_ROOT:-}" ] || export REPO_ROOT
    exec "$bin" hook "$hook" "$@"
}

substrate_engine_bin() {
    local hook="$1"
    local bin rc
    bin=$(_substrate_engine_resolve "$hook")
    rc=$?
    case "$rc" in
        0) ;;
        2) return 2 ;;
        *) return 1 ;;
    esac
    [ -z "${SUBSTRATE_DIR:-}" ] || export SUBSTRATE_DIR
    [ -z "${REPO_ROOT:-}" ] || export REPO_ROOT
    printf '%s\n' "$bin"
}

_substrate_engine_delegate() {
    local hook="$1" v1_fn="$2"
    shift 2
    local -a verb=()
    while [ "$1" != "--" ]; do
        verb+=("$1")
        shift
    done
    shift
    local bin out status
    bin=$(substrate_engine_bin "$hook")
    status=$?
    case "$status" in
        0) ;;
        2) return 2 ;;
        *) "$v1_fn" "$@"; return ;;
    esac
    out=$("$bin" "${verb[@]}" "$@")
    status=$?
    if [ "$status" -eq 2 ]; then
        "$v1_fn" "$@"
        return
    fi
    [ "$status" -eq 0 ] && [ -n "$out" ] && printf '%s\n' "$out"
    return "$status"
}
