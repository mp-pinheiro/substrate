#!/usr/bin/env bash
# Installer path containment, config seeding, and Claude/omp asset synchronization.
# Same-name unmarked assets stay repo-owned.
repo_path_safe() {
    local path="$1" label="${2:-$1}" root current part
    local parts=()
    [ -n "$path" ] || { warn "$label has an empty destination"; return 1; }
    case "$path" in
        /*) warn "$label must stay inside the repository: $path"; return 1 ;;
    esac
    root=$(pwd -P) || { warn "cannot resolve the repository root"; return 1; }
    current="$root"
    IFS='/' read -r -a parts <<< "$path"
    for part in ${parts[@]+"${parts[@]}"}; do
        case "$part" in
            "" | .) continue ;;
            ..) warn "$label escapes the repository: $path"; return 1 ;;
        esac
        current="$current/$part"
        if [ -L "$current" ]; then
            warn "$label crosses a symlink at ${current#"$root"/} — left untouched"
            return 1
        fi
    done
}
user_path_safe() {
    local path="$1" label="${2:-$1}" current part relative
    local parts=()
    case "$path" in
        "$HOME") return 0 ;;
        "$HOME"/*) relative="${path#"$HOME"/}" ;;
        *) warn "$label must stay inside HOME: $path"; return 1 ;;
    esac
    current="$HOME"
    IFS='/' read -r -a parts <<< "$relative"
    for part in ${parts[@]+"${parts[@]}"}; do
        case "$part" in
            "" | .) continue ;;
            ..) warn "$label escapes HOME: $path"; return 1 ;;
        esac
        current="$current/$part"
        if [ -L "$current" ]; then
            warn "$label crosses a symlink at ${current#"$HOME"/} — left untouched"
            return 1
        fi
    done
}
guard_vendor_downgrade() {
    local force="$1" kit_v vendored_v
    local versions=()
    [ -f .substrate/VERSION ] || return 0
    kit_v=$(cat "$KIT_ROOT/VERSION")
    vendored_v=$(cat .substrate/VERSION)
    mapfile -t versions < <(printf '%s\n%s\n' "$kit_v" "$vendored_v" | sort -V)
    if [ "${versions[${#versions[@]}-1]}" = "$vendored_v" ] \
        && [ "$vendored_v" != "$kit_v" ] \
        && [ "$force" -ne 1 ]; then
        die "vendored $vendored_v is newer than kit $kit_v — pass --force to downgrade"
    fi
}
seed_config() {
    local profiles_json="$1" staged
    repo_path_safe substrate.json "substrate configuration" || die "unsafe substrate.json destination"
    staged=$(mktemp substrate.json.XXXXXX) || die "substrate.json staging failed"
    if ! jq -n --argjson profiles "$profiles_json" '{
        version: 1,
        profiles: $profiles,
        inventory: "auto",
        unscanned: [
            "*.md", "**/*.md", "*.txt", "*.lock", "*.toml",
            "LICENSE*", "VERSION", ".gitignore", ".gitattributes", ".gitmodules",
            "*.png", "*.svg", "*.jpg", "*.csv", "Dockerfile*", "Makefile", "justfile",
            ".substrate/**", ".omp/**", ".importlinter",
            "substrate-report.md"
        ],
        protected_paths: [],
        comment: { allow_tags: ["SAFETY:", "WHY:", "PERF:", "HACK:"] },
        budgets: { max_file_lines: 500 },
        duplication: { min_tokens: 35 },
        report: { max_age_days: 14 },
        checks: { disabled: [] }
    }' > "$staged" || ! mv "$staged" substrate.json; then
        rm -f "$staged"
        die "substrate.json write failed"
    fi
}
sync_managed_asset_dir() {
    local source="$1" dest="$2" label="$3"
    local marker="$2/.substrate-managed.json" legacy_marker="$2/.substrate-managed"
    local stage backup=""
    if [ -L "$dest" ]; then
        warn "$dest is a symlink — $label left untouched"
        return 1
    fi
    if [ -e "$dest" ] && [ ! -d "$dest" ]; then
        warn "$dest is not a directory — $label left untouched"
        return 1
    fi
    if [ -L "$marker" ] || [ -L "$legacy_marker" ]; then
        warn "$dest has a symlinked ownership marker — $label left untouched"
        return 1
    fi
    if { [ -e "$marker" ] && [ ! -f "$marker" ]; } \
        || { [ -e "$legacy_marker" ] && [ ! -f "$legacy_marker" ]; }; then
        warn "$dest has a non-regular ownership marker — $label left untouched"
        return 1
    fi
    if [ -f "$marker" ] && ! jq -e '.managed_by == "substrate"' "$marker" >/dev/null 2>&1; then
        warn "$marker is not a valid Substrate ownership marker — $label left untouched"
        return 1
    fi
    if [ -e "$dest" ] && [ ! -f "$marker" ] && [ ! -f "$legacy_marker" ] \
        && ! diff -qr -x .substrate-managed -x .substrate-managed.json "$source" "$dest" >/dev/null 2>&1; then
        info "$label exists and is repo-owned — left untouched: $dest"
        return 0
    fi
    stage=$(mktemp -d "$(dirname "$dest")/.substrate-$(basename "$dest").XXXXXX") \
        || { warn "$label staging failed: $dest"; return 1; }
    if ! cp -R "$source/." "$stage/"; then
        rm -rf "$stage"
        warn "$label staging failed: $dest"
        return 1
    fi
    if [ -e "$dest" ]; then
        backup=$(mktemp -d "$(dirname "$dest")/.substrate-backup-$(basename "$dest").XXXXXX") \
            || { rm -rf "$stage"; warn "$label backup failed: $dest"; return 1; }
        rm -rf "$backup"
        if ! mv "$dest" "$backup"; then
            rm -rf "$stage"
            warn "$label backup failed: $dest"
            return 1
        fi
    fi
    if mv "$stage" "$dest" && diff -qr "$source" "$dest" >/dev/null 2>&1; then
        [ -z "$backup" ] || rm -rf "$backup"
        success "$label synchronized: $dest"
        return 0
    fi
    rm -rf "$stage" "$dest"
    if [ -n "$backup" ] && ! mv "$backup" "$dest"; then
        warn "$label synchronization and restore failed: recover $backup to $dest"
        return 1
    fi
    warn "$label synchronization failed: $dest"
    return 1
}
sync_managed_asset_file() {
    local source="$1" dest="$2" label="$3"
    local marker="$2.substrate-managed.json" legacy_marker="$2.substrate-managed"
    local staged backup dest_installed=0 marker_installed=0 restore_failed=0
    if [ -L "$dest" ] || [ -L "$marker" ] || [ -L "$legacy_marker" ]; then
        warn "$dest or its ownership marker is a symlink — $label left untouched"
        return 1
    fi
    if { [ -e "$dest" ] && [ ! -f "$dest" ]; } \
        || { [ -e "$marker" ] && [ ! -f "$marker" ]; } \
        || { [ -e "$legacy_marker" ] && [ ! -f "$legacy_marker" ]; }; then
        warn "$dest or its ownership marker is not a regular file — $label left untouched"
        return 1
    fi
    if [ -f "$marker" ] && ! jq -e '.managed_by == "substrate"' "$marker" >/dev/null 2>&1; then
        warn "$marker is not a valid Substrate ownership marker — $label left untouched"
        return 1
    fi
    if [ -e "$dest" ] && [ ! -f "$marker" ] && [ ! -f "$legacy_marker" ] \
        && ! cmp -s "$source" "$dest"; then
        info "$label exists and is repo-owned — left untouched: $dest"
        return 0
    fi
    staged=$(mktemp -d "$dest.substrate.XXXXXX") \
        || { warn "$label staging failed: $dest"; return 1; }
    if ! cp "$source" "$staged/content" \
        || ! chmod 644 "$staged/content" \
        || ! printf '{"managed_by":"substrate"}\n' > "$staged/marker"; then
        rm -rf "$staged"
        warn "$label staging failed: $dest"
        return 1
    fi
    backup=$(mktemp -d "$dest.backup.XXXXXX") || {
        rm -rf "$staged"
        warn "$label backup failed: $dest"
        return 1
    }
    if { [ -e "$dest" ] && ! cp -p "$dest" "$backup/content"; } \
        || { [ -e "$marker" ] && ! cp -p "$marker" "$backup/marker"; }; then
        rm -rf "$staged" "$backup"
        warn "$label backup failed: $dest"
        return 1
    fi
    if mv "$staged/content" "$dest"; then
        dest_installed=1
        if mv "$staged/marker" "$marker"; then
            marker_installed=1
            rm -rf "$staged" "$backup"
            rm -f "$legacy_marker"
            success "$label synchronized: $dest"
            return 0
        fi
    fi
    if [ "$dest_installed" -eq 1 ]; then
        rm -f "$dest"
        [ ! -e "$backup/content" ] || mv "$backup/content" "$dest" 2>/dev/null || restore_failed=1
    fi
    if [ "$marker_installed" -eq 1 ]; then
        rm -f "$marker"
        [ ! -e "$backup/marker" ] || mv "$backup/marker" "$marker" 2>/dev/null || restore_failed=1
    fi
    rm -rf "$staged"
    if [ "$restore_failed" -eq 1 ]; then
        warn "$label synchronization failed; recover prior files from $backup"
        return 1
    fi
    rm -rf "$backup"
    warn "$label synchronization failed: $dest"
    return 1
}
prepare_asset_root() {
    local root="$1" label="$2"
    case "$root" in
        /*) user_path_safe "$root" "$label root" || return 1 ;;
        *) repo_path_safe "$root" "$label root" || return 1 ;;
    esac
    if [ -f "$root" ] && [ ! -s "$root" ]; then
        if rm -f "$root" && mkdir -p "$root"; then
            success "$label placeholder migrated to a directory: $root"
            return 0
        fi
        warn "$label placeholder migration failed: $root"
        return 1
    fi
    if [ -e "$root" ] && [ ! -d "$root" ]; then
        warn "$root is not a directory — $label not installed"
        return 1
    fi
    mkdir -p "$root" 2>/dev/null || {
        warn "$label root is not writable: $root"
        return 1
    }
}
prepare_repo_asset_root() {
    local root="$1" label="$2" repo resolved
    RESOLVED_REPO_ASSET_ROOT="$root"
    if [ -L "$root" ]; then
        repo=$(pwd -P) || return 1
        resolved=$(realpath "$root") || { warn "$label root symlink is unresolved: $root"; return 1; }
        case "$resolved" in
            "$repo"/*) RESOLVED_REPO_ASSET_ROOT="${resolved#"$repo"/}" ;;
            *) warn "$label root symlink escapes the repository: $root"; return 1 ;;
        esac
    fi
    prepare_asset_root "$RESOLVED_REPO_ASSET_ROOT" "$label"
}
prune_managed_asset_dirs() {
    local source_root="$1" dest_root="$2" label="$3"
    local dest marker name backup
    for dest in "$dest_root"/*; do
        [ -e "$dest" ] || [ -L "$dest" ] || continue
        [ -L "$dest" ] && continue
        [ -d "$dest" ] || continue
        marker="$dest/.substrate-managed.json"
        if [ -L "$marker" ] || [ -L "$dest/.substrate-managed" ]; then
            warn "$dest has a symlinked ownership marker — retired $label left untouched"
            return 1
        fi
        if [ -f "$marker" ]; then
            if ! jq -e '.managed_by == "substrate"' "$marker" >/dev/null 2>&1; then
                warn "$marker is invalid — retired $label left untouched"
                return 1
            fi
        elif [ ! -f "$dest/.substrate-managed" ]; then
            continue
        fi
        name=$(basename "$dest")
        [ -d "$source_root/$name" ] && continue
        backup=$(mktemp -d "$dest_root/.substrate-prune-$name.XXXXXX") \
            || { warn "cannot stage retired $label $name"; return 1; }
        rm -rf "$backup"
        if ! mv "$dest" "$backup"; then
            warn "cannot stage retired $label $name"
            return 1
        fi
        if [ -e "$dest" ]; then
            mv "$backup" "$dest" 2>/dev/null
            warn "retired $label $name did not leave its active path"
            return 1
        fi
        rm -rf "$backup"
        success "retired $label removed: $dest"
    done
}
prune_managed_asset_files() {
    local source_root="$1" dest_root="$2" label="$3"
    local marker suffix name dest backup
    for marker in "$dest_root"/*.substrate-managed.json "$dest_root"/*.substrate-managed; do
        [ -f "$marker" ] || continue
        if [ -L "$marker" ]; then
            warn "$marker is a symlink — retired $label left untouched"
            return 1
        fi
        case "$marker" in
            *.substrate-managed.json)
                suffix=.substrate-managed.json
                jq -e '.managed_by == "substrate"' "$marker" >/dev/null 2>&1 || {
                    warn "$marker is invalid — retired $label left untouched"
                    return 1
                }
                ;;
            *) suffix=.substrate-managed ;;
        esac
        name=$(basename "${marker%"$suffix"}")
        [ -f "$source_root/$name" ] && continue
        dest="$dest_root/$name"
        if [ -L "$dest" ] || { [ -e "$dest" ] && [ ! -f "$dest" ]; }; then
            warn "$dest is not a regular managed file — retired $label left untouched"
            return 1
        fi
        backup=$(mktemp -d "$dest_root/.substrate-prune-$name.XXXXXX") \
            || { warn "cannot stage retired $label $name"; return 1; }
        if [ -e "$dest" ] && ! mv "$dest" "$backup/$name"; then
            rm -rf "$backup"
            warn "cannot stage retired $label $name"
            return 1
        fi
        if ! mv "$marker" "$backup/$(basename "$marker")"; then
            [ ! -e "$backup/$name" ] || mv "$backup/$name" "$dest" 2>/dev/null
            rm -rf "$backup"
            warn "cannot stage retired $label marker $name"
            return 1
        fi
        if [ -e "$dest" ] || [ -e "$marker" ]; then
            [ ! -e "$backup/$name" ] || mv "$backup/$name" "$dest" 2>/dev/null
            mv "$backup/$(basename "$marker")" "$marker" 2>/dev/null
            rm -rf "$backup"
            warn "retired $label $name did not leave its active path"
            return 1
        fi
        rm -rf "$backup"
        success "retired $label removed: $dest"
    done
}
install_harness_assets() {
    local source source_root dest_root name root rc=0
    for root in .claude/skills .omp/skills; do
        prepare_repo_asset_root "$root" "skills" || { rc=1; continue; }
        root="$RESOLVED_REPO_ASSET_ROOT"
        for source in "$KIT_ROOT"/skills/*/; do
            [ -d "$source" ] || continue
            name=$(basename "$source")
            sync_managed_asset_dir "$source" "$root/$name" "skill $name" || rc=1
        done
        prune_managed_asset_dirs "$KIT_ROOT/skills" "$root" "skill" || rc=1
    done
    for source_root in "$KIT_ROOT/agents/claude" "$KIT_ROOT/agents/omp"; do
        [ -d "$source_root" ] || continue
        case "$source_root" in
            */claude) dest_root=.claude/agents ;;
            */omp) dest_root=.omp/agents ;;
        esac
        prepare_repo_asset_root "$dest_root" "agents" || { rc=1; continue; }
        dest_root="$RESOLVED_REPO_ASSET_ROOT"
        for source in "$source_root"/*.md; do
            [ -f "$source" ] || continue
            name=$(basename "$source")
            sync_managed_asset_file "$source" "$dest_root/$name" "agent ${name%.md}" || rc=1
        done
        prune_managed_asset_files "$source_root" "$dest_root" "agent" || rc=1
    done
    return "$rc"
}
install_user_harness_assets() {
    local source source_root dest_root name root rc=0
    for root in "$HOME/.claude/skills" "$HOME/.omp/agent/skills"; do
        prepare_asset_root "$root" "user skills" || { rc=1; continue; }
        for source in "$KIT_ROOT"/skills/*/; do
            [ -d "$source" ] || continue
            name=$(basename "$source")
            sync_managed_asset_dir "$source" "$root/$name" "user skill $name" || rc=1
        done
        prune_managed_asset_dirs "$KIT_ROOT/skills" "$root" "user skill" || rc=1
    done
    for source_root in "$KIT_ROOT/agents/claude" "$KIT_ROOT/agents/omp"; do
        [ -d "$source_root" ] || continue
        case "$source_root" in
            */claude) dest_root="$HOME/.claude/agents" ;;
            */omp) dest_root="$HOME/.omp/agent/agents" ;;
        esac
        prepare_asset_root "$dest_root" "user agents" || { rc=1; continue; }
        for source in "$source_root"/*.md; do
            [ -f "$source" ] || continue
            name=$(basename "$source")
            sync_managed_asset_file "$source" "$dest_root/$name" "user agent ${name%.md}" || rc=1
        done
        prune_managed_asset_files "$source_root" "$dest_root" "user agent" || rc=1
    done
    return "$rc"
}