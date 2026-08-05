#!/usr/bin/env bash

MAINTENANCE_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=./maintenance-lib.sh
source "$MAINTENANCE_LIB_DIR/maintenance-lib.sh"
# shellcheck source=./maintenance-sync.sh
source "$MAINTENANCE_LIB_DIR/maintenance-sync.sh"
# shellcheck source=./maintenance-cli.sh
source "$MAINTENANCE_LIB_DIR/maintenance-cli.sh"
# shellcheck source=./maintenance-transaction.sh
source "$MAINTENANCE_LIB_DIR/maintenance-transaction.sh"



maintenance_resume_incomplete() {
    local stable="$1" receipt candidate manifest expected current from status path preimage desired
    local stream units commit to id transaction_dir
    receipt=$(cat "$stable") || return 1
    status=$(jq -r '.repository.status' <<< "$receipt")
    case "$status" in
        prepared|applying|applied|incomplete) ;;
        *) return 2 ;;
    esac
    [ "$(jq -r '.operation' <<< "$receipt")" = "$MAINTENANCE_OPERATION" ] \
        || { warn "incomplete $(jq -r '.operation' <<< "$receipt") transaction must be resumed first"; return 1; }
    candidate=$(jq -r '.repository.candidatePath' <<< "$receipt")
    transaction_dir=$(dirname "$candidate")
    [ -d "$candidate/.git" ] || { warn "incomplete transaction candidate is missing"; return 1; }
    from=$(jq -r '.repository.fromRevision // ""' <<< "$receipt")
    [ "$(maintenance_revision)" = "$from" ] || { warn "repository revision changed during incomplete maintenance"; return 1; }
    stream=$(mktemp) || return 1
    # PERF: one jq streams every unit field NUL-framed; NUL is the only byte a path cannot hold.
    jq -j '(.repository.units // [])[] | (.path, .preimage, .desired) | (., "\u0000")' <<< "$receipt" \
        > "$stream" || { rm -f "$stream"; return 1; }
    while IFS= read -r -d '' path <&3; do
        IFS= read -r -d '' preimage <&3 || { rm -f "$stream"; return 1; }
        IFS= read -r -d '' desired <&3 || { rm -f "$stream"; return 1; }
        current=$(maintenance_path_state "$path") || { rm -f "$stream"; return 1; }
        [ "$current" = "$preimage" ] || [ "$current" = "$desired" ] \
            || { warn "maintenance recovery blocked by drift at $path"; rm -f "$stream"; return 1; }
    done 3< "$stream"
    rm -f "$stream"
    manifest=$(mktemp) || return 1
    units=$(mktemp) || { rm -f "$manifest"; return 1; }
    jq -r '.repository.manifest[]' <<< "$receipt" > "$manifest"
    jq -r '.repository.units[].path' <<< "$receipt" > "$units"
    expected=$(jq -r '.repository.preservedDirtyFingerprint' <<< "$receipt")
    maintenance_compare_dirty_state "$manifest" "$expected" \
        || { rm -f "$manifest" "$units"; warn "maintenance recovery blocked by unrelated working-copy drift"; return 1; }
    MAINTENANCE_CHECKPOINT=$(jq -r 'if .repository.checkpointRequested then 1 else 0 end' <<< "$receipt")
    MAINTENANCE_MESSAGE=$(jq -r '.repository.message' <<< "$receipt")
    : "$MAINTENANCE_MESSAGE"
    rm -f "$candidate/gate-resume.log" "$candidate/commit-resume.log" \
        "$transaction_dir/gate-resume.log" "$transaction_dir/commit-resume.log"
    maintenance_gate_candidate "$candidate" "$transaction_dir/gate-resume.log" "$HOME" \
        || { cat "$transaction_dir/gate-resume.log" >&2; rm -f "$manifest" "$units"; return 1; }
    maintenance_apply_units "$candidate" "$stable" "$stable" || { rm -f "$manifest" "$units"; return 1; }
    maintenance_update_receipt "$stable" "$stable" '.repository.status="applied"' \
        || { rm -f "$manifest" "$units"; return 1; }
    if [ "$MAINTENANCE_CHECKPOINT" -eq 1 ]; then
        id=$(jq -r '.id' "$stable")
        commit=$(maintenance_commit_exact "$units" "$id" "$transaction_dir/commit-resume.log") \
            || { cat "$transaction_dir/commit-resume.log" >&2; rm -f "$manifest" "$units"; return 1; }
        to=$(maintenance_revision) || { rm -f "$manifest" "$units"; return 1; }
        maintenance_update_receipt "$stable" "$stable" \
            ".repository.status=\"committed\" | .repository.toRevision=\"$to\" | .repository.commit=\"$commit\" | .repository.candidatePath=null" \
            || { rm -f "$manifest" "$units"; return 1; }
        maintenance_verify_transition "$from" "$to" "$expected" \
            || { rm -f "$manifest" "$units"; return 1; }
        rm -rf "$transaction_dir"
    fi
    rm -f "$manifest" "$units"
}



maintenance_run() {
    maintenance_parse_args "$@" || return 2
    guard_vendor_downgrade "$MAINTENANCE_FORCE"
    local metadata store lock stable base manifest dirty_paths dirty_inside dirty_outside dirty_fingerprint
    local overlap tx id candidate archive render_output gate_output gate_hash changed changed_lines units units_json
    local commit_units repair_lines repair_units repair_overlap=0 transaction_receipt receipt current_dirty
    local current_fingerprint stable_status test_hook commit="" from to status external_rc=0 recover=0
    local blocked_overlap=() path applied_overlap=0
    metadata=$(maintenance_metadata_dir) || { warn "repository metadata is unavailable"; return 2; }
    git rev-parse --git-dir >/dev/null 2>&1 \
        || { warn "maintenance requires a Git worktree; colocate Jujutsu with Git"; return 2; }
    store="$metadata/substrate"
    mkdir -p "$store/maintenance" || return 2
    lock="$store/maintenance.lock"
    mkdir "$lock" 2>/dev/null || { warn "another repository maintenance transaction is active"; return 2; }
    stable="$store/maintenance-receipt.json"
    if [ -f "$stable" ]; then
        stable_status=$(jq -r '.repository.status // empty' "$stable" 2>/dev/null)
        case "$stable_status" in
            prepared|applying|incomplete) recover=1 ;;
            applied)
                jq -e '.repository.checkpointRequested == true' "$stable" >/dev/null 2>&1 \
                    && recover=1
                ;;
        esac
        if [ "$recover" -eq 1 ]; then
            if maintenance_resume_incomplete "$stable"; then
                external_rc=0
                maintenance_sync_external_units "$stable" "$stable" || external_rc=1
                rmdir "$lock" 2>/dev/null
                maintenance_finish_output "$stable"
                return "$external_rc"
            fi
            rmdir "$lock" 2>/dev/null
            return 1
        fi
    fi
    base=$(maintenance_revision) || { rmdir "$lock"; return 2; }
    manifest=$(mktemp) || { rmdir "$lock"; return 2; }
    dirty_paths=$(mktemp) || { rm -f "$manifest"; rmdir "$lock"; return 2; }
    maintenance_build_manifest "$manifest" "$MAINTENANCE_OPERATION" "$MAINTENANCE_CHECKPOINT" \
        "$MAINTENANCE_ACCEPT_BASELINE" "$MAINTENANCE_VCS" "${MAINTENANCE_PROFILES[@]}" \
        || { rm -f "$manifest" "$dirty_paths"; rmdir "$lock"; return 2; }
    maintenance_collect_dirty_paths "$dirty_paths" \
        || { rm -f "$manifest" "$dirty_paths"; rmdir "$lock"; return 2; }
    dirty_inside=$(maintenance_entries_json "$dirty_paths" "$manifest" inside) \
        || { rm -f "$manifest" "$dirty_paths"; rmdir "$lock"; return 2; }
    overlap=$(jq -r 'keys | join(", ")' <<< "$dirty_inside")
    if [ -n "$overlap" ]; then
        while IFS= read -r path; do
            if maintenance_applied_path_authorized "$stable" "$base" "$path"; then
                applied_overlap=1
            elif [ "$MAINTENANCE_CHECKPOINT" -eq 0 ] \
                && maintenance_dirty_path_seedable "$base" "$path"; then
                :
            elif maintenance_dirty_path_repairable "$base" "$path"; then
                repair_overlap=1
            else
                blocked_overlap+=("$path")
            fi
        done < <(jq -r 'keys[]' <<< "$dirty_inside")
        if [ "${#blocked_overlap[@]}" -gt 0 ]; then
            overlap=""
            for path in "${blocked_overlap[@]}"; do
                overlap="${overlap:+$overlap, }$path"
            done
            warn "maintenance overlaps dirty managed paths: $overlap"
            rm -f "$manifest" "$dirty_paths"
            rmdir "$lock" 2>/dev/null
            return 1
        fi
        [ "$applied_overlap" -eq 0 ] || info "resuming previously applied maintenance paths"
        [ "$repair_overlap" -eq 0 ] || info "repairing dirty paths with checked Substrate ownership"
    fi
    dirty_outside=$(maintenance_entries_json "$dirty_paths" "$manifest" outside) \
        || { rm -f "$manifest" "$dirty_paths"; rmdir "$lock"; return 2; }
    dirty_fingerprint=$(maintenance_json_fingerprint "$dirty_outside") \
        || { rm -f "$manifest" "$dirty_paths"; rmdir "$lock"; return 2; }
    if [ -z "$base" ] && [ "$MAINTENANCE_ACCEPT_BASELINE" -eq 1 ] \
        && [ "$(jq 'length' <<< "$dirty_outside")" -gt 0 ]; then
        warn "commit existing source before accepting its initial Substrate baseline"
        rm -f "$manifest" "$dirty_paths"
        rmdir "$lock" 2>/dev/null
        return 1
    fi
    id=$(printf '%s:%s:%s:%s' "$MAINTENANCE_OPERATION" "$base" "$$" "$(date +%s%N)" \
        | sha256sum | cut -c 1-24)
    tx="$store/maintenance/$id"
    candidate="$tx/candidate"
    archive="$tx/base.tar"
    mkdir -p "$tx/home" || return 2
    render_output="$tx/render.log"
    gate_output="$tx/gate.log"
    if ! maintenance_prepare_candidate "$candidate" "$base" "$archive" "$dirty_paths" "$manifest" \
        || ! maintenance_render_candidate "$candidate" "$tx/home" "$render_output"; then
        cat "$render_output" >&2 2>/dev/null
        rm -rf "$tx"; rm -f "$manifest" "$dirty_paths"; rmdir "$lock" 2>/dev/null
        return 1
    fi
    if ! maintenance_gate_candidate "$candidate" "$gate_output" "$HOME"; then
        cat "$gate_output" >&2
        rm -rf "$tx"; rm -f "$manifest" "$dirty_paths"; rmdir "$lock" 2>/dev/null
        return 1
    fi
    gate_hash=$(sha256sum "$gate_output" | cut -d ' ' -f 1) || return 2
    changed="$tx/changed.nul"
    changed_lines="$tx/changed.paths"
    units="$tx/units.paths"
    commit_units="$tx/commit-units.paths"
    repair_lines="$tx/repair.paths"
    repair_units="$tx/repair-units.paths"
    maintenance_candidate_changes "$candidate" "$manifest" "$changed" "$changed_lines" \
        || { rm -rf "$tx"; rm -f "$manifest" "$dirty_paths"; rmdir "$lock" 2>/dev/null; return 1; }
    maintenance_changed_units "$manifest" "$changed_lines" "$commit_units" || return 2
    : > "$repair_units"
    if [ "$repair_overlap" -eq 1 ]; then
        jq -r 'keys[]' <<< "$dirty_inside" > "$repair_lines" || return 2
        maintenance_changed_units "$manifest" "$repair_lines" "$repair_units" || return 2
    fi
    { cat "$commit_units"; cat "$repair_units"; } | LC_ALL=C sort -u > "$units" || return 2
    units_json=$(maintenance_units_json "$units" "$candidate") || return 2
    transaction_receipt="$tx/receipt.json"
    if [ ! -s "$changed_lines" ] && [ ! -s "$units" ]; then
        status=noop
        commit=""
        if [ "$MAINTENANCE_CHECKPOINT" -eq 1 ]; then status=committed; commit="$base"; fi
        receipt=$(maintenance_receipt_json "$id" "$status" "$base" "$base" "$manifest" "$changed_lines" \
            "$units_json" "$dirty_fingerprint" "$gate_hash" "" "$commit") || return 2
        maintenance_write_json "$transaction_receipt" "$receipt" || return 2
        maintenance_publish_receipt "$transaction_receipt" "$stable" || return 2
        maintenance_sync_external_units "$transaction_receipt" "$stable" || external_rc=1
        rm -rf "$tx"; rm -f "$manifest" "$dirty_paths"; rmdir "$lock" 2>/dev/null
        maintenance_finish_output "$stable"
        return "$external_rc"
    fi
    receipt=$(maintenance_receipt_json "$id" prepared "$base" "" "$manifest" "$changed_lines" \
        "$units_json" "$dirty_fingerprint" "$gate_hash" "$candidate" "") || return 2
    maintenance_write_json "$transaction_receipt" "$receipt" || return 2
    test_hook=${SUBSTRATE_MAINTENANCE_TEST_HOOK:-}
    if [ "${SUBSTRATE_MAINTENANCE_TESTING:-}" = 1 ] && [ -n "$test_hook" ]; then
        if [ ! -x "$test_hook" ] || ! "$test_hook" "$(pwd -P)"; then
            rm -rf "$tx"; rm -f "$manifest" "$dirty_paths"; rmdir "$lock" 2>/dev/null
            return 2
        fi
    fi
    if ! maintenance_units_match_preimage "$transaction_receipt"; then
        warn "managed paths changed while rendering maintenance candidate"
        rm -rf "$tx"; rm -f "$manifest" "$dirty_paths"; rmdir "$lock" 2>/dev/null
        return 1
    fi
    if [ "$(maintenance_revision)" != "$base" ]; then
        warn "repository revision changed while rendering maintenance candidate"
        rm -rf "$tx"; rm -f "$manifest" "$dirty_paths"; rmdir "$lock" 2>/dev/null
        return 1
    fi
    current_dirty=$(mktemp) || return 2
    maintenance_collect_dirty_paths "$current_dirty" || return 2
    current_fingerprint=$(maintenance_entries_json "$current_dirty" "$manifest" outside) || return 2
    current_fingerprint=$(maintenance_json_fingerprint "$current_fingerprint") || return 2
    rm -f "$current_dirty"
    if [ "$current_fingerprint" != "$dirty_fingerprint" ]; then
        warn "working copy changed while rendering maintenance candidate"
        rm -rf "$tx"; rm -f "$manifest" "$dirty_paths"; rmdir "$lock" 2>/dev/null
        return 1
    fi
    maintenance_publish_receipt "$transaction_receipt" "$stable" || return 2
    maintenance_apply_units "$candidate" "$transaction_receipt" "$stable"
    status=$?
    if [ "$status" -ne 0 ]; then
        maintenance_update_receipt "$transaction_receipt" "$stable" '.repository.status="incomplete"' || true
        warn "repository maintenance incomplete; rerun the same command to converge"
        rm -f "$manifest" "$dirty_paths"; rmdir "$lock" 2>/dev/null
        return 1
    fi
    maintenance_update_receipt "$transaction_receipt" "$stable" '.repository.status="applied"' || return 2
    if [ "$MAINTENANCE_CHECKPOINT" -eq 1 ]; then
        maintenance_compare_dirty_state "$manifest" "$dirty_fingerprint" \
            || {
                maintenance_update_receipt "$transaction_receipt" "$stable" \
                    '.repository.status="incomplete"' || true
                warn "unrelated work changed before maintenance checkpoint"
                rm -f "$manifest" "$dirty_paths"; rmdir "$lock" 2>/dev/null
                return 1
            }
        if [ -s "$commit_units" ]; then
            if ! commit=$(maintenance_commit_exact "$commit_units" "$id" "$tx/commit.log"); then
                cat "$tx/commit.log" >&2 2>/dev/null
                warn "repository maintenance applied but exact-path commit failed"
                maintenance_update_receipt "$transaction_receipt" "$stable" \
                    '.repository.status="incomplete"' || true
                rm -f "$manifest" "$dirty_paths"; rmdir "$lock" 2>/dev/null
                return 1
            fi
            if ! to=$(maintenance_revision); then
                maintenance_update_receipt "$transaction_receipt" "$stable" \
                    '.repository.status="incomplete"' || true
                rm -f "$manifest" "$dirty_paths"; rmdir "$lock" 2>/dev/null
                return 2
            fi
        else
            [ -n "$base" ] \
                || { rm -f "$manifest" "$dirty_paths"; rmdir "$lock" 2>/dev/null; return 2; }
            commit="$base"
            to="$base"
        fi
        if ! maintenance_update_receipt "$transaction_receipt" "$stable" \
            ".repository.status=\"committed\" | .repository.toRevision=\"$to\" | .repository.commit=\"$commit\" | .repository.candidatePath=null"; then
            rm -f "$manifest" "$dirty_paths"; rmdir "$lock" 2>/dev/null
            return 2
        fi
        if ! maintenance_verify_transition "$base" "$to" "$dirty_fingerprint"; then
            warn "maintenance commit exists but its exact-state receipt failed verification"
            rm -rf "$tx"; rm -f "$manifest" "$dirty_paths"; rmdir "$lock" 2>/dev/null
            return 1
        fi
    fi
    maintenance_sync_external_units "$transaction_receipt" "$stable" || external_rc=1
    if [ "$MAINTENANCE_CHECKPOINT" -eq 1 ]; then
        rm -rf "$tx"
    fi
    rm -f "$manifest" "$dirty_paths"
    rmdir "$lock" 2>/dev/null
    maintenance_finish_output "$stable"
    return "$external_rc"
}
