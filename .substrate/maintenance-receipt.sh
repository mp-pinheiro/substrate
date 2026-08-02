#!/usr/bin/env bash
# Exact-state maintenance receipt validation and overlap authorization.
maintenance_receipt_path() {
    local metadata
    metadata=$(maintenance_metadata_dir) || return 1
    printf '%s/substrate/maintenance-receipt.json\n' "$metadata"
}

maintenance_verify_transition() {
    local from="$1" to="$2" fingerprint="$3" receipt current changed path expected actual
    receipt=$(maintenance_receipt_path) || return 1
    [ -f "$receipt" ] || return 1
    jq -e --arg from "$from" --arg to "$to" --arg fingerprint "$fingerprint" '
        .repository.status == "committed"
        and (.repository.fromRevision // "") == $from
        and .repository.toRevision == $to
        and .repository.preservedDirtyFingerprint == $fingerprint' "$receipt" >/dev/null \
        || return 1
    current=$(maintenance_revision) || return 1
    [ "$current" = "$to" ] || return 1
    changed=$(mktemp) || return 1
    if [ -n "$from" ] && git cat-file -e "$from^{commit}" 2>/dev/null; then
        git diff --name-only -z --no-renames "$from" "$to" -- > "$changed" || { rm -f "$changed"; return 1; }
    else
        git diff-tree --root --name-only -z -r --no-commit-id "$to" -- > "$changed" \
            || { rm -f "$changed"; return 1; }
    fi
    expected=$(jq -c '.repository.changedPaths | sort' "$receipt") || { rm -f "$changed"; return 1; }
    actual=$(while IFS= read -r -d '' path; do
        case "$path" in *$'\n'*|*$'\t'*) exit 1 ;; esac
        printf '%s\n' "$path"
    done < "$changed" | jq -Rsc 'split("\n") | map(select(length > 0)) | sort') \
        || { rm -f "$changed"; return 1; }
    rm -f "$changed"
    [ "$actual" = "$expected" ]
}
maintenance_repository_receipt_matches() {
    local path="${1:-}" current expected total index unit desired manifest dirty inside outside fingerprint
    [ -n "$path" ] || path=$(maintenance_receipt_path) || return 1
    [ -f "$path" ] || return 1
    jq -e --arg version "$(cat .substrate/VERSION 2>/dev/null)" --arg vcs "$(maintenance_vcs)" '
        .schemaVersion == 1
        and .engineVersion == $version
        and .repository.status == "committed"
        and .repository.checkpointRequested == true
        and .repository.vcs == $vcs
        and .repository.commit == .repository.toRevision
        and (.repository.gateHash | test("^[0-9a-f]{64}$"))
        and .noPush == true' "$path" >/dev/null 2>&1 || return 1
    current=$(maintenance_revision) || return 1
    expected=$(jq -r '.repository.toRevision' "$path") || return 1
    [ "$current" = "$expected" ] || return 1
    manifest=$(mktemp) || return 1
    dirty=$(mktemp) || { rm -f "$manifest"; return 1; }
    jq -r '.repository.manifest[]' "$path" > "$manifest" \
        || { rm -f "$manifest" "$dirty"; return 1; }
    maintenance_collect_dirty_paths "$dirty" \
        || { rm -f "$manifest" "$dirty"; return 1; }
    inside=$(maintenance_entries_json "$dirty" "$manifest" inside) \
        || { rm -f "$manifest" "$dirty"; return 1; }
    outside=$(maintenance_entries_json "$dirty" "$manifest" outside) \
        || { rm -f "$manifest" "$dirty"; return 1; }
    rm -f "$manifest" "$dirty"
    [ "$(jq 'length' <<< "$inside")" -eq 0 ] || return 1
    fingerprint=$(maintenance_json_fingerprint "$outside") || return 1
    expected=$(jq -r '.repository.preservedDirtyFingerprint' "$path") || return 1
    [ "$fingerprint" = "$expected" ] || return 1
    total=$(jq '.repository.units | length' "$path") || return 1
    for ((index=0; index<total; index++)); do
        unit=$(jq -r --argjson index "$index" '.repository.units[$index].path' "$path") || return 1
        desired=$(jq -r --argjson index "$index" '.repository.units[$index].desired' "$path") || return 1
        [ "$(maintenance_path_state "$unit")" = "$desired" ] || return 1
    done
}

maintenance_receipt_matches() {
    local path
    path=$(maintenance_receipt_path) || return 1
    maintenance_repository_receipt_matches "$path" || return 1
    jq -e '.repoRuntime.status == "passed"' "$path" >/dev/null 2>&1
}

maintenance_compare_dirty_state() {
    local manifest="$1" expected="$2" paths current fingerprint
    paths=$(mktemp) || return 1
    maintenance_collect_dirty_paths "$paths" || { rm -f "$paths"; return 1; }
    current=$(maintenance_entries_json "$paths" "$manifest" outside) || { rm -f "$paths"; return 1; }
    rm -f "$paths"
    fingerprint=$(maintenance_json_fingerprint "$current") || return 1
    [ "$fingerprint" = "$expected" ]
}
maintenance_applied_path_authorized() {
    local stable="$1" base="$2" path="$3" receipt total index unit desired
    [ -f "$stable" ] || return 1
    receipt=$(cat "$stable") || return 1
    [ "$(jq -r '.repository.status' <<< "$receipt")" = applied ] || return 1
    [ "$(jq -r '.repository.fromRevision // ""' <<< "$receipt")" = "$base" ] || return 1
    total=$(jq '.repository.units | length' <<< "$receipt") || return 1
    for ((index=0; index<total; index++)); do
        unit=$(jq -r --argjson index "$index" '.repository.units[$index].path' <<< "$receipt") || return 1
        case "$path" in
            "$unit"|"$unit"/*)
                desired=$(jq -r --argjson index "$index" '.repository.units[$index].desired' <<< "$receipt") \
                    || return 1
                [ "$(maintenance_path_state "$unit")" = "$desired" ]
                return
                ;;
        esac
    done
    return 1
}
