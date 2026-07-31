# Sourced by the runner and every check. Provides logging, config access,
# inventory iteration, metric emission, and fail-closed helpers.
# Requires: REPO_ROOT, SUBSTRATE_DIR, CONFIG, LANGMAP, INVENTORY, METRICS exported by the runner.

info()    { printf '\033[0;34m[+]\033[0m %s\n' "$*"; }
success() { printf '\033[0;32m[ok]\033[0m %s\n' "$*"; }
warn()    { printf '\033[0;33m[!]\033[0m %s\n' "$*"; }

# infra failure: message, then the fail-closed exit the runner treats as "cannot pass blind"
die_infra() {
    printf '%s\n' "$*" >&2
    exit 3
}

cfg() {
    jq -r "$1 // empty" "$CONFIG"
}

cfg_json() {
    jq -c "$1" "$CONFIG"
}

# metric <name> <value>  — lower is better; runner ratchets it against the baseline
metric() {
    jq -cn --arg n "$1" --arg v "$2" '{name: $n, value: ($v | tonumber)}' >> "$METRICS" \
        || die_infra "metric emission failed for $1=$2"
}

inventory() {
    cat "$INVENTORY"
}

# inv_glob <glob>... — inventory entries matching any glob (bash case matching, no external tools)
inv_glob() {
    local f g
    while IFS= read -r f; do
        for g in "$@"; do
            # shellcheck disable=SC2254 # globs are the contract here
            case "$f" in
                $g) printf '%s\n' "$f"; break ;;
            esac
        done
    done < "$INVENTORY"
}

# unscanned ledger: scanning checks consult scan_target, never claimed alone —
# a ledgered file is excluded from EVERY scanner, or the ledger is a lie
_UNSCANNED_LOADED=0
declare -a _UNSCANNED=()
unscanned_match() {
    if [ "$_UNSCANNED_LOADED" -eq 0 ]; then
        mapfile -t _UNSCANNED < <(jq -r '(.unscanned // [])[]' "$CONFIG")
        _UNSCANNED_LOADED=1
    fi
    local g
    for g in ${_UNSCANNED[@]+"${_UNSCANNED[@]}"}; do
        # shellcheck disable=SC2254 # globs are the contract here
        case "$1" in
            $g) return 0 ;;
        esac
    done
    return 1
}

scan_target() {
    claimed "$1" && ! unscanned_match "$1"
}

# style scanners (comments, duplication, budgets) skip exempt-mode claims —
# exempt means another tool owns the file's style, not that it may not parse
scan_source() {
    local e
    e=$(lang_entry "$1")
    [ -n "$e" ] || return 1
    unscanned_match "$1" && return 1
    [ "$(jq -r '.mode' <<< "$e")" != "exempt" ]
}

# langmap accessors; empty output = unclaimed. Extension first, then shebang
# fallback so extensionless executables (bin/*, hooks) stay claimed source.
lang_entry() {
    local f="$1" ext=".${1##*.}" e first
    e=$(jq -c --arg e "$ext" '.[$e] // empty' "$LANGMAP")
    if [ -z "$e" ] && [ -f "$f" ]; then
        IFS= read -r first < "$f" || first=""
        case "$first" in
            '#!'*)
                local -a parts=()
                read -r -a parts <<< "${first#\#!}"
                local interp
                interp=$(basename "${parts[0]:-}")
                [ "$interp" = "env" ] && interp=$(basename "${parts[1]:-}")
                e=$(jq -c --arg i "$interp" \
                    'first((.__shebang__ // [])[] | select(.match | index($i)) | .entry) // empty' "$LANGMAP")
                ;;
        esac
    fi
    [ -n "$e" ] && printf '%s\n' "$e"
    return 0
}

claimed() {
    [ -n "$(lang_entry "$1")" ]
}

have() {
    command -v "$1" >/dev/null 2>&1
}

# require_bin <bin> <hint> — fatal when absent locally AND in CI; the check decides
# whether to call this (load-bearing) or downgrade to a CI-only requirement.
require_bin() {
    have "$1" || die_infra "$1 is required but not installed — $2"
}

# require_bin_ci <bin> <hint> — warn-and-skip locally, fatal under CI.
# Caller must treat return 1 as "skip this check" and say so out loud.
require_bin_ci() {
    if have "$1"; then
        return 0
    fi
    if [ -n "${CI:-}" ]; then
        die_infra "$1 missing in CI — toolchain install is broken ($2)"
    fi
    warn "$1 not installed — check skipped locally, CI runs it ($2)"
    return 1
}
