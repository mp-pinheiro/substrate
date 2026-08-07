#!/usr/bin/env bash
# Candidate rendering, gated apply, receipt transitions, and exact-path commits.
maintenance_overlay_worktree() {
    local candidate="$1" paths="$2" manifest="$3" base="$4" phase="$5" source kit path
    source=$(pwd -P) || return 1
    kit=$(cd "$KIT_ROOT" && pwd -P) || return 1
    [ "$phase" != kit ] || [ "$source" = "$kit" ] || return 0
    while IFS= read -r -d '' path; do
        case "$phase" in
            kit)
                maintenance_path_in_manifest "$path" "$manifest" && continue
                ;;
            seed)
                maintenance_path_in_manifest "$path" "$manifest" || continue
                [ "$MAINTENANCE_CHECKPOINT" -eq 0 ] \
                    && maintenance_dirty_path_seedable "$base" "$path" \
                    || continue
                ;;
            *) return 1 ;;
        esac
        case "$path" in
            ''|/*|..|../*|*/../*|*/..|-*|*$'\t'*|*$'\n'*) return 1 ;;
        esac
        [ ! -L "$path" ] || return 1
        (
            cd "$candidate" || exit 1
            repo_path_safe "$path" "maintenance candidate overlay" || exit 1
            rm -rf -- "$path"
            if [ -e "$source/$path" ]; then
                mkdir -p "$(dirname "$path")" || exit 1
                cp -a -- "$source/$path" "$path" || exit 1
            fi
        ) || return 1
    done < "$paths"
}

maintenance_prepare_candidate() {
    local candidate="$1" base="$2" archive="$3" dirty_paths="$4" manifest="$5"
    mkdir -p "$candidate" || return 1
    if [ -n "$base" ] && git cat-file -e "$base^{commit}" 2>/dev/null; then
        git archive --format=tar --output="$archive" "$base" || return 1
        tar -xf "$archive" -C "$candidate" || return 1
        maintenance_preserve_modes "$candidate" || return 1
    fi
    maintenance_overlay_worktree "$candidate" "$dirty_paths" "$manifest" "$base" kit || return 1
    git -C "$candidate" init -q --initial-branch=main || return 1
    git -C "$candidate" config user.name substrate-maintenance || return 1
    git -C "$candidate" config user.email substrate@localhost || return 1
    git -C "$candidate" add -f -A || return 1
    git -C "$candidate" commit -q --allow-empty -m 'chore: seed maintenance candidate' || return 1
    maintenance_overlay_worktree "$candidate" "$dirty_paths" "$manifest" "$base" seed || return 1
}

maintenance_render_candidate() {
    local candidate="$1" render_home="$2" output="$3" profiles_csv force_flag=()
    profiles_csv=$(IFS=,; printf '%s' "${MAINTENANCE_PROFILES[*]}")
    [ "$MAINTENANCE_FORCE" -eq 0 ] || force_flag=(--force)
    (
        cd "$candidate" || exit 2
        export HOME="$render_home"
        export SUBSTRATE_NO_USER_HARNESS=1
        export SUBSTRATE_MAINTENANCE_RENDER=1
        export SUBSTRATE_RENDER_VCS="$MAINTENANCE_VCS"
        if [ "$MAINTENANCE_OPERATION" = update ]; then
            "$KIT_ROOT/bin/substrate" __maintenance-render update --apply "${force_flag[@]}"
        else
            "$KIT_ROOT/bin/substrate" __maintenance-render "$MAINTENANCE_OPERATION" \
                --profile "$profiles_csv" --vcs "$MAINTENANCE_VCS" "${force_flag[@]}"
        fi
    ) > "$output" 2>&1
}

maintenance_gate_candidate() {
    local candidate="$1" output="$2" caller_home="$3"
    (
        cd "$candidate" || exit 2
        git add -f -A || exit 2
        export HOME="$caller_home"
        unset SUBSTRATE_FILE_LIST
        if [ ! -f substrate-baseline.json ]; then
            if [ "$MAINTENANCE_ACCEPT_BASELINE" -eq 1 ]; then
                .substrate/gate.sh --update-baseline || exit
            elif [ "$MAINTENANCE_CHECKPOINT" -eq 1 ]; then
                printf 'maintenance blocked: initial debt requires --accept-baseline\n' >&2
                exit 3
            fi
        fi
        if [ "$MAINTENANCE_CHECKPOINT" -eq 1 ] && [ -f substrate-baseline.json ]; then
            .substrate/gate.sh --tighten || exit
            .substrate/gate.sh
        else
            .substrate/gate.sh
        fi
    ) > "$output" 2>&1
}

maintenance_candidate_changes() {
    local candidate="$1" manifest="$2" changed="$3" changed_lines="$4" path
    git -C "$candidate" add -f -A || return 1
    git -C "$candidate" diff --cached --name-only -z --no-renames HEAD -- > "$changed" || return 1
    : > "$changed_lines"
    while IFS= read -r -d '' path; do
        case "$path" in ''|/*|..|../*|*/../*|*/..|-*|*$'\t'*|*$'\n'*) return 1 ;; esac
        maintenance_path_in_manifest "$path" "$manifest" \
            || { printf 'maintenance renderer wrote outside its manifest: %s\n' "$path" >&2; return 1; }
        printf '%s\n' "$path" >> "$changed_lines"
    done < "$changed"
    LC_ALL=C sort -u "$changed_lines" -o "$changed_lines"
}

maintenance_changed_units() {
    local manifest="$1" changed_lines="$2" output="$3" unit path
    : > "$output"
    while IFS= read -r unit; do
        while IFS= read -r path; do
            case "$path" in "$unit"|"$unit"/*) printf '%s\n' "$unit" >> "$output"; break ;; esac
        done < "$changed_lines"
    done < "$manifest"
}

maintenance_units_json() {
    local units="$1" candidate="$2" objects unit preimage desired
    objects=$(mktemp) || return 1
    while IFS= read -r unit; do
        [ -n "$unit" ] || continue
        preimage=$(maintenance_path_state "$unit") || { rm -f "$objects"; return 1; }
        desired=$(cd "$candidate" && maintenance_path_state "$unit") || { rm -f "$objects"; return 1; }
        jq -cn --arg path "$unit" --arg preimage "$preimage" --arg desired "$desired" \
            '{path:$path,preimage:$preimage,desired:$desired}' >> "$objects" || { rm -f "$objects"; return 1; }
    done < "$units"
    jq -sc '.' "$objects"
    local rc=$?
    rm -f "$objects"
    return "$rc"
}

maintenance_receipt_json() {
    local id="$1" status="$2" from="$3" to="$4" manifest="$5" changed="$6" units="$7"
    local dirty_fingerprint="$8" gate_hash="$9" candidate="${10}" commit="${11:-}" manifest_json changed_json
    manifest_json=$(jq -Rsc 'split("\n") | map(select(length > 0))' "$manifest") || return 1
    changed_json=$(jq -Rsc 'split("\n") | map(select(length > 0))' "$changed") || return 1
    jq -cn --arg id "$id" --arg operation "$MAINTENANCE_OPERATION" \
        --arg engineVersion "$(cat "$KIT_ROOT/VERSION")" --arg status "$status" \
        --arg vcs "$MAINTENANCE_VCS" --arg from "$from" --arg to "$to" \
        --arg dirty "$dirty_fingerprint" --arg gateHash "$gate_hash" \
        --arg candidate "$candidate" --arg commit "$commit" --arg message "$MAINTENANCE_MESSAGE" \
        --arg checkpoint "$MAINTENANCE_CHECKPOINT" --argjson manifest "$manifest_json" \
        --argjson changed "$changed_json" --argjson units "$units" \
        --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        {schemaVersion:1,id:$id,operation:$operation,engineVersion:$engineVersion,
         repository:{status:$status,vcs:$vcs,fromRevision:(if $from == "" then null else $from end),
          toRevision:(if $to == "" then null else $to end),commit:(if $commit == "" then null else $commit end),
          message:$message,checkpointRequested:($checkpoint == "1"),manifest:$manifest,
          changedPaths:$changed,units:$units,preservedDirtyFingerprint:$dirty,gateHash:$gateHash,
          candidatePath:(if $candidate == "" then null else $candidate end)},
         repoRuntime:{status:"pending"},userHarness:{status:"pending"},noPush:true,at:$at}'
}

maintenance_publish_receipt() {
    local transaction_receipt="$1" stable_receipt="$2" value
    value=$(cat "$transaction_receipt") || return 1
    maintenance_write_json "$stable_receipt" "$value"
}

maintenance_update_receipt() {
    local transaction_receipt="$1" stable_receipt="$2" filter="$3" value next
    value=$(cat "$transaction_receipt") || return 1
    next=$(jq -c "$filter" <<< "$value") || return 1
    maintenance_write_json "$transaction_receipt" "$next" || return 1
    maintenance_write_json "$stable_receipt" "$next"
}

maintenance_mark_unit_applied() {
    local transaction_receipt="$1" stable_receipt="$2" unit="$3" value next
    value=$(cat "$transaction_receipt") || return 1
    next=$(jq -c --arg unit "$unit" '
        .repository.status="applying"
        | .repository.units |= map(if .path == $unit then . + {applied:true} else . end)' <<< "$value") \
        || return 1
    maintenance_write_json "$transaction_receipt" "$next" || return 1
    maintenance_write_json "$stable_receipt" "$next"
}

maintenance_apply_units() {
    local candidate="$1" transaction_receipt="$2" stable_receipt="$3"
    local unit desired current count=0 fail_after stream
    fail_after=${SUBSTRATE_MAINTENANCE_FAIL_AFTER:-0}
    stream=$(mktemp) || return 1
    # PERF: one NUL-framed jq pass; per-unit receipt writes never reorder units or touch path/desired.
    jq -j '(.repository.units // [])[] | (.path, .desired) | (., "\u0000")' "$transaction_receipt" \
        > "$stream" || { rm -f "$stream"; return 1; }
    while IFS= read -r -d '' unit <&3; do
        IFS= read -r -d '' desired <&3 || { rm -f "$stream"; return 1; }
        current=$(maintenance_path_state "$unit") || { rm -f "$stream"; return 1; }
        if [ "$current" != "$desired" ]; then
            maintenance_apply_unit "$candidate" "$unit" "$desired" || { rm -f "$stream"; return 1; }
        fi
        maintenance_mark_unit_applied "$transaction_receipt" "$stable_receipt" "$unit" \
            || { rm -f "$stream"; return 1; }
        count=$((count + 1))
        if [ "${SUBSTRATE_MAINTENANCE_TESTING:-}" = 1 ] && [ "$fail_after" -eq "$count" ]; then
            maintenance_update_receipt "$transaction_receipt" "$stable_receipt" '.repository.status="incomplete"' || true
            rm -f "$stream"
            return 75
        fi
    done 3< "$stream"
    rm -f "$stream"
}


maintenance_commit_exact() {
    local units_file="$1" id="$2" output="$3" commit temp_index
    local units=()
    if [ "${SUBSTRATE_MAINTENANCE_TESTING:-}" = 1 ] \
        && [ "${SUBSTRATE_MAINTENANCE_FAIL_COMMIT:-0}" = 1 ]; then
        printf 'injected maintenance commit failure\n' > "$output"
        return 75
    fi
    mapfile -t units < "$units_file"
    [ "${#units[@]}" -gt 0 ] || return 2
    export SUBSTRATE_MAINTENANCE_ID="$id"
    if [ "$MAINTENANCE_VCS" = jj ]; then
        jj commit --message "$MAINTENANCE_MESSAGE" -- "${units[@]}" > "$output" 2>&1 \
            || { unset SUBSTRATE_MAINTENANCE_ID; return 1; }
        commit=$(jj log -r @- --no-graph -T 'commit_id' 2>/dev/null) \
            || { unset SUBSTRATE_MAINTENANCE_ID; return 1; }
    else
        temp_index=$(mktemp) || { unset SUBSTRATE_MAINTENANCE_ID; return 1; }
        rm -f "$temp_index"
        export GIT_INDEX_FILE="$temp_index"
        if git rev-parse --verify HEAD >/dev/null 2>&1; then
            git read-tree HEAD || { unset GIT_INDEX_FILE SUBSTRATE_MAINTENANCE_ID; rm -f "$temp_index"; return 1; }
        else
            git read-tree --empty || { unset GIT_INDEX_FILE SUBSTRATE_MAINTENANCE_ID; rm -f "$temp_index"; return 1; }
        fi
        if ! git add -f -A -- "${units[@]}" \
            || ! git commit -m "$MAINTENANCE_MESSAGE" > "$output" 2>&1; then
            unset GIT_INDEX_FILE SUBSTRATE_MAINTENANCE_ID
            rm -f "$temp_index"
            return 1
        fi
        commit=$(git rev-parse HEAD) \
            || { unset GIT_INDEX_FILE SUBSTRATE_MAINTENANCE_ID; rm -f "$temp_index"; return 1; }
        unset GIT_INDEX_FILE
        rm -f "$temp_index"
        git reset --quiet HEAD -- "${units[@]}" \
            || { unset SUBSTRATE_MAINTENANCE_ID; return 1; }
    fi
    unset SUBSTRATE_MAINTENANCE_ID
    printf '%s\n' "$commit"
}
