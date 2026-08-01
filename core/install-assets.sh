#!/usr/bin/env bash
# Synchronizes kit-owned Claude and omp agents and skills without replacing
# same-name repo-owned assets.

sync_managed_asset_dir() {
    local source="$1" dest="$2" label="$3"
    local marker="$2/.substrate-managed.json" legacy_marker="$2/.substrate-managed"
    if [ -L "$dest" ]; then
        warn "$dest is a symlink — $label left untouched"
        return 1
    fi
    if [ ! -e "$dest" ]; then
        mkdir -p "$(dirname "$dest")" \
            && cp -R "$source" "$dest" \
            && success "$label installed: $dest" \
            && return 0
        warn "$label install failed: $dest"
        return 1
    fi
    if [ ! -d "$dest" ]; then
        warn "$dest is not a directory — $label left untouched"
        return 1
    fi
    if [ ! -f "$marker" ] && [ ! -f "$legacy_marker" ] \
        && ! diff -qr -x .substrate-managed -x .substrate-managed.json "$source" "$dest" >/dev/null 2>&1; then
        info "$label exists and is repo-owned — left untouched: $dest"
        return 0
    fi
    if cp -R "$source/." "$dest/" 2>/dev/null; then
        rm -f "$legacy_marker"
        success "$label synchronized: $dest"
        return 0
    fi
    warn "$label synchronization failed: $dest"
    return 1
}

sync_managed_asset_file() {
    local source="$1" dest="$2" label="$3"
    local marker="$2.substrate-managed.json" legacy_marker="$2.substrate-managed"
    if [ -L "$dest" ]; then
        warn "$dest is a symlink — $label left untouched"
        return 1
    fi
    if [ -e "$dest" ] && [ ! -f "$marker" ] && [ ! -f "$legacy_marker" ] \
        && ! cmp -s "$source" "$dest"; then
        info "$label exists and is repo-owned — left untouched: $dest"
        return 0
    fi
    if mkdir -p "$(dirname "$dest")" \
        && cp "$source" "$dest" \
        && printf '{"managed_by":"substrate"}\n' > "$marker"; then
        rm -f "$legacy_marker"
        success "$label synchronized: $dest"
        return 0
    fi
    warn "$label synchronization failed: $dest"
    return 1
}

prepare_asset_root() {
    local root="$1" label="$2"
    if [ -L "$root" ] && [ ! -d "$root" ]; then
        warn "$root is a non-directory symlink — $label not installed"
        return 1
    fi
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

install_harness_assets() {
    local source source_root dest_root name root rc=0
    for root in .claude/skills .omp/skills; do
        prepare_asset_root "$root" "skills" || { rc=1; continue; }
        for source in "$KIT_ROOT"/skills/*/; do
            [ -d "$source" ] || continue
            name=$(basename "$source")
            sync_managed_asset_dir "$source" "$root/$name" "skill $name" || rc=1
        done
    done
    for source_root in "$KIT_ROOT/agents/claude" "$KIT_ROOT/agents/omp"; do
        [ -d "$source_root" ] || continue
        case "$source_root" in
            */claude) dest_root=.claude/agents ;;
            */omp) dest_root=.omp/agents ;;
        esac
        prepare_asset_root "$dest_root" "agents" || { rc=1; continue; }
        for source in "$source_root"/*.md; do
            [ -f "$source" ] || continue
            name=$(basename "$source")
            sync_managed_asset_file "$source" "$dest_root/$name" "agent ${name%.md}" || rc=1
        done
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
    done
    return "$rc"
}