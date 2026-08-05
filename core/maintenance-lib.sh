#!/usr/bin/env bash

maintenance_metadata_dir() {
    local git_dir
    if git_dir=$(git rev-parse --git-common-dir 2>/dev/null); then
        case "$git_dir" in
            /*) printf '%s\n' "$git_dir" ;;
            *) printf '%s\n' "$(pwd -P)/$git_dir" ;;
        esac
    elif [ -d .jj ]; then
        printf '%s/.jj\n' "$(pwd -P)"
    else
        return 1
    fi
}

maintenance_vcs() {
    if [ -d .jj ] && command -v jj >/dev/null 2>&1; then
        printf 'jj\n'
    elif git rev-parse --git-dir >/dev/null 2>&1; then
        printf 'git\n'
    else
        return 1
    fi
}

maintenance_revision() {
    local revision
    if [ "$(maintenance_vcs)" = jj ]; then
        jj log -r @- --no-graph -T 'commit_id' 2>/dev/null
    elif revision=$(git rev-parse --verify HEAD 2>/dev/null); then
        printf '%s\n' "$revision"
    else
        printf '\n'
    fi
}

maintenance_write_json() {
    local path="$1" value="$2" staged
    mkdir -p "$(dirname "$path")" || return 1
    staged=$(mktemp "$path.XXXXXX") || return 1
    if printf '%s\n' "$value" > "$staged" && chmod 600 "$staged" && mv -f "$staged" "$path"; then
        return 0
    fi
    rm -f "$staged"
    return 1
}

maintenance_path_state() {
    local path="$1" records nodes sorted node rel mode hash target
    records=$(mktemp) || return 1
    if [ -L "$path" ]; then
        target=$(readlink "$path") || { rm -f "$records"; return 1; }
        printf 'symlink\0%s\0' "$target" > "$records"
    elif [ -f "$path" ]; then
        mode=$(stat -c '%a' "$path") || { rm -f "$records"; return 1; }
        hash=$(sha256sum "$path" | cut -d ' ' -f 1) || { rm -f "$records"; return 1; }
        printf 'file\0%s\0%s\0' "$mode" "$hash" > "$records"
    elif [ -d "$path" ]; then
        nodes=$(mktemp) || { rm -f "$records"; return 1; }
        sorted=$(mktemp) || { rm -f "$records" "$nodes"; return 1; }
        find "$path" -mindepth 1 -print0 > "$nodes" \
            || { rm -f "$records" "$nodes" "$sorted"; return 1; }
        LC_ALL=C sort -z "$nodes" > "$sorted" \
            || { rm -f "$records" "$nodes" "$sorted"; return 1; }
        mode=$(stat -c '%a' "$path") || { rm -f "$records" "$nodes" "$sorted"; return 1; }
        printf 'dir\0.\0%s\0' "$mode" > "$records"
        while IFS= read -r -d '' node; do
            rel=${node#"$path"/}
            if [ -L "$node" ]; then
                target=$(readlink "$node") || { rm -f "$records" "$nodes" "$sorted"; return 1; }
                printf 'symlink\0%s\0%s\0' "$rel" "$target" >> "$records"
            elif [ -f "$node" ]; then
                mode=$(stat -c '%a' "$node") || { rm -f "$records" "$nodes" "$sorted"; return 1; }
                hash=$(sha256sum "$node" | cut -d ' ' -f 1) || { rm -f "$records" "$nodes" "$sorted"; return 1; }
                printf 'file\0%s\0%s\0%s\0' "$rel" "$mode" "$hash" >> "$records"
            elif [ -d "$node" ]; then
                mode=$(stat -c '%a' "$node") || { rm -f "$records" "$nodes" "$sorted"; return 1; }
                printf 'dir\0%s\0%s\0' "$rel" "$mode" >> "$records"
            else
                rm -f "$records" "$nodes" "$sorted"
                return 1
            fi
        done < "$sorted"
        rm -f "$nodes" "$sorted"
    elif [ -e "$path" ]; then
        rm -f "$records"
        return 1
    else
        printf 'missing\0' > "$records"
    fi
    hash=$(sha256sum "$records" | cut -d ' ' -f 1)
    rm -f "$records"
    printf '%s\n' "$hash"
}
maintenance_preserve_modes() {
    local candidate="$1" path rel current
    while IFS= read -r -d '' path; do
        rel=${path#"$candidate"/}
        current="./$rel"
        [ ! -L "$path" ] && [ ! -L "$current" ] || continue
        if { [ -f "$path" ] && [ -f "$current" ]; } \
            || { [ -d "$path" ] && [ -d "$current" ]; }; then
            chmod --reference="$current" "$path" || return 1
        fi
    done < <(find "$candidate" -mindepth 1 -print0)
}

maintenance_entry_state() {
    local path="$1" status
    if [ -d "$path" ] && ! [ -L "$path" ] && git -C "$path" rev-parse HEAD >/dev/null 2>&1; then
        status=$(git -C "$path" status --porcelain=v1 --untracked-files=all 2>/dev/null) || return 1
        printf 'submodule:%s:%s\n' "$(git -C "$path" rev-parse HEAD)" \
            "$(printf '%s' "$status" | sha256sum | cut -d ' ' -f 1)"
    else
        maintenance_path_state "$path"
    fi
}

maintenance_collect_dirty_paths() {
    local output="$1" vcs raw
    vcs=$(maintenance_vcs) || return 1
    raw=$(mktemp) || return 1
    if [ "$vcs" = jj ]; then
        jj diff --template 'path ++ "\0"' > "$raw" 2>/dev/null \
            || { rm -f "$raw"; return 1; }
    else
        if git rev-parse HEAD >/dev/null 2>&1; then
            git diff --name-only -z --no-renames HEAD -- > "$raw" \
                || { rm -f "$raw"; return 1; }
        else
            git ls-files -z --cached > "$raw" || { rm -f "$raw"; return 1; }
        fi
        git ls-files -z --others --exclude-standard >> "$raw" \
            || { rm -f "$raw"; return 1; }
    fi
    LC_ALL=C sort -zu "$raw" > "$output"
    local rc=$?
    rm -f "$raw"
    return "$rc"
}

maintenance_path_in_manifest() {
    local path="$1" manifest="$2" unit
    while IFS= read -r unit; do
        [ -n "$unit" ] || continue
        case "$path" in
            "$unit"|"$unit"/*) return 0 ;;
        esac
    done < "$manifest"
    return 1
}

maintenance_entries_json() {
    local paths="$1" manifest="$2" selection="$3" objects path state match
    objects=$(mktemp) || return 1
    while IFS= read -r -d '' path; do
        case "$path" in
            ''|/*|..|../*|*/../*|*/..|-*|*$'\t'*|*$'\n'*) rm -f "$objects"; return 1 ;;
        esac
        match=0
        maintenance_path_in_manifest "$path" "$manifest" && match=1
        if { [ "$selection" = inside ] && [ "$match" -eq 0 ]; } \
            || { [ "$selection" = outside ] && [ "$match" -eq 1 ]; }; then
            continue
        fi
        state=$(maintenance_entry_state "$path") || { rm -f "$objects"; return 1; }
        jq -cn --arg path "$path" --arg state "$state" '{($path):$state}' >> "$objects" \
            || { rm -f "$objects"; return 1; }
    done < "$paths"
    jq -sc 'add // {}' "$objects"
    local rc=$?
    rm -f "$objects"
    return "$rc"
}

maintenance_json_fingerprint() {
    local normalized
    normalized=$(jq -cS . <<< "$1") || return 1
    printf '%s' "$normalized" | sha256sum | cut -d ' ' -f 1
}
maintenance_base_marker_owned() {
    local base="$1" marker="$2" value
    [ -n "$base" ] || return 1
    value=$(git show "$base:$marker" 2>/dev/null) || return 1
    jq -e '.managed_by == "substrate"' <<< "$value" >/dev/null 2>&1
}

maintenance_dirty_path_repairable() {
    local base="$1" path="$2" marker dir first left right
    if [ -e "$path" ] || [ -L "$path" ]; then
        [ -f "$path" ] && [ ! -L "$path" ] || return 1
    fi
    case "$path" in
        .substrate/*)
            git cat-file -e "$base:.substrate/VERSION" 2>/dev/null
            return
            ;;
        .omp/extensions/substrate-quality.ts)
            left=$(git show "$base:$path" 2>/dev/null) || return 1
            right=$(git show "$base:core/omp/substrate-quality.ts" 2>/dev/null) || return 1
            [ "$left" = "$right" ]
            return
            ;;
        .github/workflows/*)
            first=$(git show "$base:$path" 2>/dev/null | {
                IFS= read -r line || true
                printf '%s' "$line"
            })
            [ "$first" = "# substrate-managed" ]
            return
            ;;
        *.substrate-managed.json)
            maintenance_base_marker_owned "$base" "$path"
            return
            ;;
    esac
    marker="$path.substrate-managed.json"
    maintenance_base_marker_owned "$base" "$marker" && return 0
    dir=$(dirname "$path")
    while [ "$dir" != "." ] && [ "$dir" != "/" ]; do
        maintenance_base_marker_owned "$base" "$dir/.substrate-managed.json" && return 0
        dir=$(dirname "$dir")
    done
    return 1
}

maintenance_dirty_path_seedable() {
    local base="$1" path="$2" p dir dest content first
    [ ! -L "$path" ] || return 1
    case "$path" in
        substrate.json|.claude/settings.json|.omp/lsp.json|justfile|Makefile|docs/jj-workflow.md)
            return 0
            ;;
        .github/workflows/*)
            if content=$(git show "$base:$path" 2>/dev/null); then
                first=${content%%$'\n'*}
                [ "$first" != "# substrate-managed" ]
                return
            fi
            return 0
            ;;
        .claude/skills/*|.omp/skills/*|.claude/agents/*|.omp/agents/*)
            maintenance_dirty_path_repairable "$base" "$path" && return 1
            return 0
            ;;
    esac
    for p in "${MAINTENANCE_PROFILES[@]}"; do
        dir=$(profile_dir "$p") || continue
        while IFS= read -r dest; do
            [ "$path" != "$dest" ] || return 0
        done < <(jq -r '(.templates // [])[] | .dest' "$dir/profile.json")
    done
    return 1
}

maintenance_units_match_preimage() {
    local receipt="$1" stream unit preimage
    stream=$(mktemp) || return 1
    # PERF: one jq streams every unit field NUL-framed; NUL is the only byte a path cannot hold.
    jq -j '(.repository.units // [])[] | (.path, .preimage) | (., "\u0000")' "$receipt" > "$stream" \
        || { rm -f "$stream"; return 1; }
    while IFS= read -r -d '' unit <&3; do
        IFS= read -r -d '' preimage <&3 || { rm -f "$stream"; return 1; }
        [ "$(maintenance_path_state "$unit")" = "$preimage" ] || { rm -f "$stream"; return 1; }
    done 3< "$stream"
    rm -f "$stream"
}

maintenance_manifest_add() {
    local path="${1#./}" output="$2"
    case "$path" in
        ''|/*|..|../*|*/../*|*/..|-*|*$'\t'*|*$'\n'*) return 1 ;;
    esac
    printf '%s\n' "$path" >> "$output"
}

maintenance_manifest_asset_root() {
    local path="$1" output="$2" repo resolved
    if [ -L "$path" ]; then
        repo=$(pwd -P) || return 1
        resolved=$(realpath "$path") || return 1
        case "$resolved" in
            "$repo"/*) maintenance_manifest_add "${resolved#"$repo"/}" "$output" ;;
            *) return 1 ;;
        esac
    else
        maintenance_manifest_add "$path" "$output"
    fi
}

maintenance_build_manifest() {
    local output="$1" operation="$2" checkpoint="$3" accept_baseline="$4" vcs="$5"
    shift 5
    local profiles=("$@") p dir dest raw
    raw=$(mktemp) || return 1
    maintenance_manifest_add .substrate "$raw" || return 1
    maintenance_manifest_add .omp/extensions/substrate-quality.ts "$raw" || return 1
    if [ "$operation" != update ]; then
        for dest in substrate.json .github/workflows .claude/settings.json .omp/lsp.json justfile Makefile; do
            maintenance_manifest_add "$dest" "$raw" || return 1
        done
        for dest in .claude/skills .omp/skills .claude/agents .omp/agents; do
            maintenance_manifest_asset_root "$dest" "$raw" || return 1
        done
        [ "$vcs" != jj ] || maintenance_manifest_add docs/jj-workflow.md "$raw" || return 1
        for p in "${profiles[@]}"; do
            dir=$(profile_dir "$p") || { rm -f "$raw"; return 1; }
            while IFS= read -r dest; do
                [ -n "$dest" ] && maintenance_manifest_add "$dest" "$raw"
            done < <(jq -r '(.templates // [])[] | .dest' "$dir/profile.json")
        done
    fi
    if [ "$checkpoint" -eq 1 ] || [ "$accept_baseline" -eq 1 ]; then
        maintenance_manifest_add substrate-baseline.json "$raw" || return 1
    fi
    LC_ALL=C sort -u "$raw" > "$output"
    local rc=$?
    rm -f "$raw"
    return "$rc"
}

maintenance_apply_unit() {
    local candidate="$1" unit="$2" desired="$3" current parent name stage backup="" actual
    current=$(maintenance_path_state "$unit") || return 1
    [ "$current" != "$desired" ] || return 0
    repo_path_safe "$unit" "maintenance path $unit" || return 1
    parent=$(dirname "$unit")
    name=$(basename "$unit")
    mkdir -p "$parent" || return 1
    stage=$(mktemp -d "$parent/.substrate-maint-stage-$name.XXXXXX") || return 1
    if [ -e "$candidate/$unit" ] || [ -L "$candidate/$unit" ]; then
        cp -a "$candidate/$unit" "$stage/value" || { rm -rf "$stage"; return 1; }
    fi
    if [ -e "$unit" ] || [ -L "$unit" ]; then
        backup=$(mktemp -d "$parent/.substrate-maint-backup-$name.XXXXXX") \
            || { rm -rf "$stage"; return 1; }
        rm -rf "$backup"
        mv "$unit" "$backup" || { rm -rf "$stage"; return 1; }
    fi
    if [ -e "$stage/value" ] || [ -L "$stage/value" ]; then
        if ! mv "$stage/value" "$unit"; then
            [ -z "$backup" ] || mv "$backup" "$unit" 2>/dev/null
            rm -rf "$stage"
            return 1
        fi
    fi
    rm -rf "$stage"
    actual=$(maintenance_path_state "$unit") || actual=""
    if [ "$actual" != "$desired" ]; then
        rm -rf "$unit"
        [ -z "$backup" ] || mv "$backup" "$unit" 2>/dev/null
        return 1
    fi
    if [ -n "$backup" ] && ! rm -rf "$backup"; then
        rm -rf "$unit"
        mv "$backup" "$unit" 2>/dev/null
        return 1
    fi
}

MAINTENANCE_RECEIPT_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=./maintenance-receipt.sh
source "$MAINTENANCE_RECEIPT_LIB_DIR/maintenance-receipt.sh"

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-}" in
        verify-transition) shift; [ "$#" -eq 3 ] || exit 2; maintenance_verify_transition "$@" ;;
        repository-receipt-matches)
            [ "$#" -eq 1 ] || exit 2
            receipt=$(maintenance_receipt_path) || exit 1
            maintenance_repository_receipt_matches "$receipt"
            ;;
        receipt-matches) [ "$#" -eq 1 ] || exit 2; maintenance_receipt_matches ;;
        *) exit 2 ;;
    esac
fi

