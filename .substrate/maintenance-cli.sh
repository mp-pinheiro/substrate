#!/usr/bin/env bash

maintenance_parse_args() {
    MAINTENANCE_OPERATION="$1"
    shift
    MAINTENANCE_PROFILE_CSV=""
    MAINTENANCE_FORCE=0
    MAINTENANCE_CHECKPOINT=0
    MAINTENANCE_ACCEPT_BASELINE=0
    MAINTENANCE_ACCEPT_REGRESSION=""
    MAINTENANCE_JSON=0
    MAINTENANCE_REPO_ONLY=0
    MAINTENANCE_REQUESTED_VCS=auto
    MAINTENANCE_MESSAGE=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --profile) [ "$#" -ge 2 ] || return 2; MAINTENANCE_PROFILE_CSV="$2"; shift 2 ;;
            --vcs) [ "$#" -ge 2 ] || return 2; MAINTENANCE_REQUESTED_VCS="$2"; shift 2 ;;
            --force) MAINTENANCE_FORCE=1; shift ;;
            --apply) shift ;;
            --checkpoint) MAINTENANCE_CHECKPOINT=1; shift ;;
            --accept-baseline) MAINTENANCE_ACCEPT_BASELINE=1; shift ;;
            --accept-regression)
                warn "--accept-regression requires the keyed form: --accept-regression=<metric>[,<metric>]"
                return 2 ;;
            --accept-regression=*)
                MAINTENANCE_ACCEPT_REGRESSION="${1#--accept-regression=}"
                [ -n "$MAINTENANCE_ACCEPT_REGRESSION" ] || { warn "--accept-regression= needs at least one metric"; return 2; }
                shift ;;
            --message) [ "$#" -ge 2 ] || return 2; MAINTENANCE_MESSAGE="$2"; shift 2 ;;
            --json) MAINTENANCE_JSON=1; shift ;;
            --repo-only) MAINTENANCE_REPO_ONLY=1; shift ;;
            *) warn "unknown $MAINTENANCE_OPERATION flag: $1"; return 2 ;;
        esac
    done
    case "$MAINTENANCE_REQUESTED_VCS" in auto|git|jj) ;; *) return 2 ;; esac
    MAINTENANCE_VCS=$(maintenance_vcs) || return 2
    if [ "$MAINTENANCE_REQUESTED_VCS" != auto ] && [ "$MAINTENANCE_REQUESTED_VCS" != "$MAINTENANCE_VCS" ]; then
        warn "requested VCS $MAINTENANCE_REQUESTED_VCS does not match active $MAINTENANCE_VCS repository"
        return 2
    fi
    if [ -z "$MAINTENANCE_PROFILE_CSV" ]; then
        if [ ! -f substrate.json ] && [ "$MAINTENANCE_OPERATION" != update ]; then
            warn "$MAINTENANCE_OPERATION requires --profile a,b"
            return 2
        fi
        jq -e '(.profiles | type == "array") and (.profiles | length > 0)' substrate.json >/dev/null 2>&1 \
            || { warn "$MAINTENANCE_OPERATION requires a valid substrate.json"; return 2; }
        MAINTENANCE_PROFILE_CSV=$(jq -r '.profiles | join(",")' substrate.json)
    fi
    MAINTENANCE_PROFILES=(base)
    local requested=() profile
    declare -A seen=([base]=1)
    IFS=',' read -r -a requested <<< "$MAINTENANCE_PROFILE_CSV"
    for profile in "${requested[@]}"; do
        [ -n "$profile" ] || continue
        if [ -z "${seen[$profile]:-}" ]; then
            profile_dir "$profile" >/dev/null || { warn "unknown profile: $profile"; return 2; }
            MAINTENANCE_PROFILES+=("$profile")
            seen[$profile]=1
        fi
    done
    [ "${#MAINTENANCE_PROFILES[@]}" -gt 1 ] || [ "$MAINTENANCE_PROFILE_CSV" = base ] \
        || { warn "at least one profile is required"; return 2; }
    if [ -z "$MAINTENANCE_MESSAGE" ]; then
        case "$MAINTENANCE_OPERATION" in
            init) MAINTENANCE_MESSAGE='chore(substrate): initialize' ;;
            bootstrap) MAINTENANCE_MESSAGE='chore(substrate): synchronize' ;;
            update) MAINTENANCE_MESSAGE='chore(substrate): update engine' ;;
        esac
    fi
    local conv='^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([^)]+\))?!?: [^[:space:]]'
    if [ "$MAINTENANCE_CHECKPOINT" -eq 1 ]; then
        printf '%s\n' "$MAINTENANCE_MESSAGE" | grep -Eq "$conv" || return 2
        [ "${#MAINTENANCE_MESSAGE}" -le 50 ] || { warn "checkpoint message exceeds 50 characters"; return 2; }
    fi
    : "$MAINTENANCE_FORCE" "$MAINTENANCE_ACCEPT_BASELINE" "$MAINTENANCE_JSON" "$MAINTENANCE_REPO_ONLY"
}
