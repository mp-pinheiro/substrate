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

# Render 0x1F (US) bytes as \x1f so error messages are readable.
render_1f() {
    printf '%s' "${1//$'\x1f'/\\x1f}"
}

cfg() {
    jq -r "$1 // empty" "$CONFIG"
}

cfg_json() {
    jq -c "$1" "$CONFIG"
}

metric() {
    jq -cn --arg n "$1" --arg v "$2" '{name: $n, value: ($v | tonumber)}' >> "$METRICS" \
        || die_infra "metric emission failed for $1=$2"
}

metric_hi() {
    jq -cn --arg n "$1" --arg v "$2" '{name: $n, value: ($v | tonumber), dir: "hi"}' >> "$METRICS" \
        || die_infra "metric_hi emission failed for $1=$2"
}

cfg_check() {
    jq -r --arg n "${SUBSTRATE_CHECK_NAME:-}" \
        '(.checks.config // {})[$n]'"${1:-}"' // empty' "$CONFIG" 2>/dev/null
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

# claims cache: the runner resolves every inventory claim once into CLAIMS;
# standalone check runs (no CLAIMS in the environment) keep per-file resolution.
_CLAIMS_STATE=""
declare -A _CLAIM_PROFILE=() _CLAIM_AST=() _CLAIM_MODE=() _CLAIM_ENTRY=()
load_claims() {
    [ -z "$_CLAIMS_STATE" ] || return 0
    if [ -z "${CLAIMS:-}" ] || [ ! -f "$CLAIMS" ]; then
        _CLAIMS_STATE=none
        return 0
    fi
    local p prof ast mode entry
    while IFS=$'\x1f' read -r p prof ast mode entry; do
        [ -n "$p" ] || continue
        _CLAIM_PROFILE[$p]=$prof
        _CLAIM_AST[$p]=$ast
        _CLAIM_MODE[$p]=$mode
        _CLAIM_ENTRY[$p]=$entry
    done < "$CLAIMS"
    _CLAIMS_STATE=table
}

scan_target() {
    claimed "$1" && ! unscanned_match "$1"
}

# style scanners (comments, duplication, budgets) skip exempt-mode claims —
# exempt means another tool owns the file's style, not that it may not parse
scan_source() {
    load_claims
    if [ "$_CLAIMS_STATE" = table ]; then
        [ -n "${_CLAIM_ENTRY[$1]:-}" ] || return 1
        unscanned_match "$1" && return 1
        [ "${_CLAIM_MODE[$1]}" != "exempt" ]
        return $?
    fi
    local e
    e=$(lang_entry "$1")
    [ -n "$e" ] || return 1
    unscanned_match "$1" && return 1
    [ "$(jq -r '.mode' <<< "$e")" != "exempt" ]
}

# profile_files <profile> [ast_lang] [predicate=scan_source] — claimed inventory
# entries, one per line; scan_target keeps exempt-mode claims in scope.
profile_files() {
    local want="$1" lang="${2:-}" pred="${3:-scan_source}" f entry
    load_claims
    if [ "$_CLAIMS_STATE" = table ]; then
        while IFS= read -r f; do
            [ "${_CLAIM_PROFILE[$f]:-}" = "$want" ] || continue
            if [ -n "$lang" ]; then
                [ "${_CLAIM_AST[$f]:-}" = "$lang" ] || continue
            fi
            "$pred" "$f" || continue
            printf '%s\n' "$f"
        done < "$INVENTORY"
        return 0
    fi
    while IFS= read -r f; do
        "$pred" "$f" || continue
        entry=$(lang_entry "$f")
        [ -n "$entry" ] || continue
        [ "$(jq -r '.profile' <<< "$entry")" = "$want" ] || continue
        if [ -n "$lang" ]; then
            [ "$(jq -r '.ast_lang // empty' <<< "$entry")" = "$lang" ] || continue
        fi
        printf '%s\n' "$f"
    done < "$INVENTORY"
}

# profile_files_ext <profile> <.ext> — profile_files narrowed to one extension
profile_files_ext() {
    local want="$1" ext="$2" f
    while IFS= read -r f; do
        case "$f" in
            *"$ext") printf '%s\n' "$f" ;;
        esac
    done < <(profile_files "$want")
}

# langmap accessors; empty output = unclaimed. Extension first, then shebang
# fallback so extensionless executables (bin/*, hooks) stay claimed source.
shebang_interp() {
    local first interp
    local -a parts=()
    IFS= read -r first < "$1" || first=""
    case "$first" in
        '#!'*)
            read -r -a parts <<< "${first#\#!}"
            interp=$(basename "${parts[0]:-}")
            [ "$interp" = "env" ] && interp=$(basename "${parts[1]:-}")
            printf '%s\n' "$interp"
            ;;
    esac
    return 0
}

lang_entry_unscoped() {
    local f="$1" ext=".${1##*.}" e interp
    e=$(jq -c --arg e "$ext" '.[$e] // empty' "$LANGMAP")
    if [ -z "$e" ] && [ -f "$f" ]; then
        interp=$(shebang_interp "$f")
        [ -z "$interp" ] || e=$(jq -c --arg i "$interp" \
            'first((.__shebang__ // [])[] | select(.match | index($i)) | .entry) // empty' "$LANGMAP")
    fi
    [ -n "$e" ] && printf '%s\n' "$e"
    return 0
}

lang_entry() {
    load_claims
    if [ "$_CLAIMS_STATE" = table ]; then
        [ -n "${_CLAIM_ENTRY[$1]:-}" ] && printf '%s\n' "${_CLAIM_ENTRY[$1]}"
        return 0
    fi
    local e
    e=$(lang_entry_unscoped "$1")
    if [ -n "$e" ] && ! scope_allows "$1" "$(jq -r '.profile' <<< "$e")"; then
        return 0
    fi
    [ -n "$e" ] && printf '%s\n' "$e"
    return 0
}

scope_allows() {
    local f="$1" profile="$2"
    jq -e '.scopes // empty | length > 0' "$CONFIG" >/dev/null 2>&1 || return 0
    local scope_path profiles_json restricted=0
    while IFS=$'\t' read -r scope_path profiles_json; do
        [ -n "$scope_path" ] || continue
        case "$f" in
            "$scope_path"*)
                restricted=1
                jq -e --arg p "$profile" 'index($p) != null' <<< "$profiles_json" >/dev/null 2>&1 && return 0
                ;;
        esac
    done < <(jq -r '.scopes | to_entries[] | "\(.key)\t\(.value.profiles)"' "$CONFIG" 2>/dev/null)
    [ "$restricted" -eq 0 ]
}

claimed() {
    load_claims
    if [ "$_CLAIMS_STATE" = table ]; then
        [ -n "${_CLAIM_ENTRY[$1]:-}" ]
        return $?
    fi
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

resolve_sg() {
    if have ast-grep; then
        SG=(ast-grep)
    elif have bunx; then
        SG=(bunx --yes @ast-grep/cli@0.45.0)
    elif [ -n "${CI:-}" ]; then
        die_infra "ast-grep unavailable in CI (install @ast-grep/cli or bun) — cannot pass blind"
    else
        warn "ast-grep unavailable — check skipped locally, CI runs it"
        return 1
    fi
}

sg_scan() {
    local lang="$1" pattern="$2"; shift 2
    SG=()
    resolve_sg || exit 0
    local errf out rc
    errf=$(mktemp)
    out=$("${SG[@]}" run --lang "$lang" --pattern "$pattern" --json=stream "$@" 2>"$errf")
    rc=$?
    if [ "$rc" -eq 1 ] && [ -z "$out" ]; then
        rm -f "$errf"
        return 1
    fi
    if [ "$rc" -ne 0 ]; then
        cat "$errf" >&2
        rm -f "$errf"
        die_infra "ast-grep failed on pattern '$pattern' (rc=$rc) — cannot pass blind"
    fi
    rm -f "$errf"
    printf '%s' "$out"
}

cfg_check_json() {
    jq -c --arg n "${SUBSTRATE_CHECK_NAME:-}" \
        '(.checks.config // {})[$n]'"${1:-}"' // empty' "$CONFIG" 2>/dev/null
}
