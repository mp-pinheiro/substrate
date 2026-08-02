#!/usr/bin/env bash
# User-scoped harness installation sourced by core/install-lib.sh.

migrate_repo_omp_extension() {
    local path=.omp/extensions/substrate-quality.ts hash="" rest=""
    repo_path_safe .omp/extensions "omp extension directory" || return 1
    repo_path_safe "$path" "legacy omp extension" || return 1
    [ -e "$path" ] || return 0
    if [ -L "$path" ] || [ ! -f "$path" ]; then
        warn "$path is not a regular managed file — left untouched"
        return 1
    fi
    read -r hash rest < <(sha256sum "$path") || {
        warn "cannot fingerprint legacy omp extension: $path"
        return 1
    }
    case "$hash" in
        f73e3997cbdd1c6e565af9cfc3042dec0c67ea5aea3b75caa7fe49d137ba69d9 \
        | b13bf3484d22844a47f14a33fa7cf830e2bc678a136c63316695ebcb298d6a87)
            rm -f "$path" || { warn "legacy omp extension removal failed: $path"; return 1; }
            success "retired repo-local omp extension: $path"
            ;;
        *)
            warn "$path is repo-owned or customized (sha256 $hash) and can shadow the user-level Substrate extension — move or remove it explicitly"
            return 1
            ;;
    esac
}
install_user_harness() {
    if [ "${SUBSTRATE_NO_USER_HARNESS:-}" = "1" ]; then
        info "user harness skipped (SUBSTRATE_NO_USER_HARNESS=1)"
        return 0
    fi
    local rc=0 path
    local omp_root="$HOME/.omp/agent/extensions" omp_dest="$HOME/.omp/agent/extensions/substrate-quality.ts"
    local omp_module_root="$omp_root/substrate-quality"
    local omp_runtime_dest="$omp_module_root/runtime.ts" omp_identity_dest="$omp_module_root/identity.ts"
    local omp_lifecycle_dest="$omp_module_root/lifecycle.ts"
    local claude_root="$HOME/.claude/hooks" claude_dest="$HOME/.claude/hooks/substrate-launch.sh"
    local template="$KIT_ROOT/core/claude-hooks-user.json" settings="$HOME/.claude/settings.json" merged
    for path in \
        "$omp_root" "$omp_dest" \
        "$omp_module_root" "$omp_runtime_dest" "$omp_lifecycle_dest" "$omp_identity_dest" \
        "$claude_root" "$claude_dest" "$settings" \
        "$HOME/.claude/skills" "$HOME/.claude/agents" \
        "$HOME/.omp/agent/skills" "$HOME/.omp/agent/agents"; do
        user_path_safe "$path" "user harness path" || return 1
    done
    # agent-level only — ~/.omp/profiles/* must never be touched by this installer
    if [ -L "$omp_root" ] || [ -L "$omp_dest" ] || [ -L "$omp_module_root" ] \
        || [ -L "$omp_runtime_dest" ] || [ -L "$omp_lifecycle_dest" ] || [ -L "$omp_identity_dest" ] \
        || { [ -e "$omp_dest" ] && [ ! -f "$omp_dest" ]; } \
        || { [ -e "$omp_module_root" ] && [ ! -d "$omp_module_root" ]; } \
        || { [ -e "$omp_runtime_dest" ] && [ ! -f "$omp_runtime_dest" ]; } \
        || { [ -e "$omp_lifecycle_dest" ] && [ ! -f "$omp_lifecycle_dest" ]; } \
        || { [ -e "$omp_identity_dest" ] && [ ! -f "$omp_identity_dest" ]; }; then
        warn "user-level omp extension path is a symlink or incompatible type — left untouched"
        rc=1
    elif mkdir -p "$omp_root" "$omp_module_root" 2>/dev/null \
        && copy_atomic_preserving_mode "$omp_runtime_dest" "$KIT_ROOT/core/omp/substrate-quality/runtime.ts" \
        && copy_atomic_preserving_mode "$omp_lifecycle_dest" "$KIT_ROOT/core/omp/substrate-quality/lifecycle.ts" \
        && copy_atomic_preserving_mode "$omp_identity_dest" "$KIT_ROOT/core/omp/substrate-quality/identity.ts" \
        && copy_atomic_preserving_mode "$omp_dest" "$KIT_ROOT/core/omp/substrate-quality.ts"; then
        success "user-level omp extension: ~/.omp/agent/extensions/substrate-quality.ts + modules"
    else
        warn "user-level omp extension install failed — sessions rooted outside substrate repos run unguarded"
        rc=1
    fi

    if [ -L "$claude_root" ] || [ -L "$claude_dest" ] \
        || { [ -e "$claude_dest" ] && [ ! -f "$claude_dest" ]; }; then
        warn "user-level Claude launcher path is a symlink — left untouched"
        return 1
    fi
    if mkdir -p "$claude_root" 2>/dev/null \
        && cp "$KIT_ROOT/core/substrate-launch.sh" "$claude_dest" 2>/dev/null \
        && chmod +x "$claude_dest" 2>/dev/null; then
        success "user-level Claude launcher: ~/.claude/hooks/substrate-launch.sh"
    else
        warn "user-level Claude launcher install failed"
        return 1
    fi
    install_user_harness_assets || rc=1


    if [ -L "$settings" ]; then
        warn "$settings is a symlink — left untouched; merge manually from $template"
        return 1
    fi
    if [ -e "$settings" ] && [ ! -f "$settings" ]; then
        warn "$settings is not a regular file — left untouched"
        return 1
    fi
    if [ -f "$settings" ] && jq -e . "$settings" >/dev/null 2>&1; then
        if ! merged=$(merge_hook_groups "$settings" "$template"); then
            warn "user Claude settings merge failed — $settings left untouched"
            return 1
        fi
        replace_preserving_mode "$settings" "$merged" "$template" || return 1
    elif [ -f "$settings" ]; then
        warn "$settings exists but is not valid JSON — left untouched; merge manually from $template"
        return 1
    else
        cp "$template" "$settings" || { warn "failed to write $settings"; return 1; }
    fi
    success "user-level Claude hooks wired in $settings"
    return "$rc"
}
