#!/usr/bin/env bash
# Installer library sourced by bin/substrate: everything cmd_init arms in a
# repo (templates, CI, hooks, harnesses, VCS gates, skills, recipes, jj).

# Requires: KIT_ROOT, info/success/warn/die, profile_dir from the caller.


file_mode() {
    stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null
}

replace_preserving_mode() {
    local path="$1" content="$2" template="$3" mode="" tmp
    if [ -L "$path" ]; then
        warn "$path is a symlink — left untouched; merge manually from $template"
        return 1
    fi
    mode=$(file_mode "$path") || mode=""
    if ! tmp=$(mktemp "$path.XXXXXX" 2>/dev/null); then
        warn "cannot stage next to $path — merge the hooks manually from $template"
        return 1
    fi
    if ! printf '%s\n' "$content" > "$tmp"; then
        rm -f "$tmp"
        warn "staging write failed for $path"
        return 1
    fi
    [ -n "$mode" ] && chmod "$mode" "$tmp" 2>/dev/null
    if mv -f "$tmp" "$path" 2>/dev/null; then
        return 0
    fi
    rm -f "$tmp"
    warn "$path is not replaceable — merge the hooks manually from $template"
    return 1
}

copy_atomic_preserving_mode() {
    local path="$1" source="$2" mode="" tmp
    if [ -L "$path" ]; then
        warn "$path is a symlink — left untouched"
        return 1
    fi
    mode=$(file_mode "$path") || mode=""
    if ! tmp=$(mktemp "$path.XXXXXX" 2>/dev/null); then
        warn "cannot stage next to $path"
        return 1
    fi
    if ! cp "$source" "$tmp"; then
        rm -f "$tmp"
        warn "staging copy failed for $path"
        return 1
    fi
    [ -n "$mode" ] && chmod "$mode" "$tmp" 2>/dev/null
    if mv -f "$tmp" "$path" 2>/dev/null; then
        return 0
    fi
    rm -f "$tmp"
    warn "$path is not replaceable"
    return 1
}

# shellcheck source=./install-assets.sh
source "$KIT_ROOT/core/install-assets.sh"
# shellcheck source=./vendor-source.sh
source "$KIT_ROOT/core/vendor-source.sh"
# shellcheck source=./user-harness.sh
source "$KIT_ROOT/core/user-harness.sh"
merge_hook_groups() {
    local settings="$1" template="$2"
    jq --argjson extra "$(cat "$template")" '
        def current_managed_commands:
            [$extra.hooks | to_entries[]? | .value[]? | .hooks[]? | .command? | select(type == "string")];
        def managed_command:
            (.command // "") as $command
            | ((current_managed_commands | index($command)) != null)
                or ($command | test("^bash \"\\$\\{CLAUDE_PROJECT_DIR:-\\.\\}/\\.substrate/hooks/[A-Za-z0-9._-]+\\.sh\"([ ][A-Za-z0-9._-]+)*$"))
                or ($command | test("^substrate-engine hook [A-Za-z0-9._-]+([ ][A-Za-z0-9._-]+)*$"))
                or ($command | test("^bash \"\\$HOME/\\.claude/hooks/substrate-launch\\.sh\" [A-Za-z0-9._-]+([ ][A-Za-z0-9._-]+)*$"));
        def strip_managed($groups):
            [$groups[]?
                | .hooks = [(.hooks // [])[] | select(managed_command | not)]
                | select((.hooks | length) > 0)];
        .hooks.PreToolUse = (strip_managed((.hooks.PreToolUse // [])) + ($extra.hooks.PreToolUse // []))
        | .hooks.PostToolUse = (strip_managed((.hooks.PostToolUse // [])) + ($extra.hooks.PostToolUse // []))
        | .hooks.SessionStart = (strip_managed((.hooks.SessionStart // [])) + ($extra.hooks.SessionStart // []))
        | .hooks.Stop = (strip_managed((.hooks.Stop // [])) + ($extra.hooks.Stop // []))
        | .hooks.SessionEnd = (strip_managed((.hooks.SessionEnd // [])) + ($extra.hooks.SessionEnd // []))
    ' "$settings"
}


sync_managed_workflow() {
    local source="$1" dest="$2" force="$3" label="$4" staged
    repo_path_safe "$dest" "$label" || return 1
    if [ -e "$dest" ] && [ ! -f "$dest" ]; then
        warn "$dest is not a regular workflow file — left untouched"
        return 1
    fi
    staged=$(mktemp "$dest.substrate.XXXXXX") || { warn "$label staging failed"; return 1; }
    if ! { printf '# substrate-managed\n'; cat "$source"; } > "$staged"; then
        rm -f "$staged"
        warn "$label staging failed"
        return 1
    fi
    chmod 644 "$staged"

    if [ -f "$dest" ] && grep -qx '# substrate-repo-owned' "$dest"; then
        rm -f "$staged"
        info "$label repo-owned: $dest"
        return 0
    fi
    if [ -f "$dest" ] && ! grep -qx '# substrate-managed' "$dest"; then
        if cmp -s "$dest" "$source"; then
            info "adopting legacy substrate workflow: $dest"
        elif [ "$force" -ne 1 ]; then
            rm -f "$staged"
            warn "$dest is not substrate-managed — left untouched (rerun bootstrap --force to adopt it)"
            return 1
        else
            info "adopting workflow with --force: $dest"
        fi
    fi
    if [ -f "$dest" ] && cmp -s "$staged" "$dest"; then
        rm -f "$staged"
        info "$label current: $dest"
        return 0
    fi
    if mv -f "$staged" "$dest"; then
        success "$label synchronized: $dest"
        return 0
    fi
    rm -f "$staged"
    warn "$label synchronization failed: $dest"
    return 1
}

install_ci() {
    local force="$1"; shift
    local profiles=("$@") p d lines=() l
    for p in "${profiles[@]}"; do
        d=$(profile_dir "$p") || continue
        while IFS= read -r l; do
            [ -n "$l" ] && lines+=("$l")
        done < <(jq -r '(.ci // [])[]' "$d/profile.json")
    done
    repo_path_safe .github/workflows "GitHub workflow directory" || return 1
    mkdir -p .github/workflows
    local out=.github/workflows/substrate-gate.yml line trimmed rendered rc=0
    rendered=$(mktemp) || { warn "gate workflow staging failed"; return 1; }
    if ! while IFS= read -r line; do
        trimmed="${line#"${line%%[![:space:]]*}"}"
        if [ "$trimmed" = "# substrate:profile-toolchain" ]; then
            for l in ${lines[@]+"${lines[@]}"}; do
                printf '          %s\n' "$l"
            done
        else
            printf '%s\n' "$line"
        fi
    done < "$KIT_ROOT/core/ci/github-gate.yml" > "$rendered"; then
        rm -f "$rendered"
        warn "gate workflow rendering failed"
        return 1
    fi
    sync_managed_workflow "$rendered" "$out" "$force" "CI workflow" || rc=1
    rm -f "$rendered"
    sync_managed_workflow "$KIT_ROOT/core/ci/github-report.yml" \
        .github/workflows/substrate-report.yml "$force" "report schedule" || rc=1
    return "$rc"
}


install_hooks_config() {
    local template="$KIT_ROOT/core/claude-hooks.json" settings=.claude/settings.json merged
    repo_path_safe .claude "Claude configuration directory" || return 1
    repo_path_safe "$settings" "Claude settings" || return 1
    mkdir -p .claude
    if [ -e "$settings" ] && [ ! -f "$settings" ]; then
        warn "$settings is not a regular file — left untouched"
        return 1
    fi
    if [ -f "$settings" ] && jq -e . "$settings" >/dev/null 2>&1; then
        if ! merged=$(merge_hook_groups "$settings" "$template"); then
            warn "Claude settings merge failed — $settings left untouched"
            return 1
        fi
        replace_preserving_mode "$settings" "$merged" "$template" || return 1
    elif [ -f "$settings" ]; then
        warn "$settings exists but is not valid JSON — left untouched; merge the hooks manually from $template"
        return 1
    else
        cp "$template" "$settings" || { warn "failed to write $settings"; return 1; }
    fi
    success "Claude hooks wired in $settings"
}


install_git_hook() {
    local path="$1" body="$2" name staged
    name=$(basename "$path")
    if [ -L "$path" ]; then
        warn "$name is a symlink — Substrate hook not installed"
        return 1
    fi
    if [ -e "$path" ] && { [ ! -f "$path" ] || ! grep -q '^# substrate-managed$' "$path"; }; then
        warn "$name exists and is not substrate-managed — left untouched; chain it to the Substrate hook"
        return 1
    fi
    staged=$(mktemp "$path.XXXXXX") || { warn "git $name hook staging failed"; return 1; }
    if printf '#!/usr/bin/env bash\n# substrate-managed\n%s\n' "$body" > "$staged" \
        && chmod +x "$staged" \
        && mv -f "$staged" "$path"; then
        success "git $name hook installed"
        return 0
    fi
    rm -f "$staged"
    warn "git $name hook install failed"
    return 1
}

install_vcs_hooks() {
    local rc=0 hooks_dir
    if git rev-parse --git-dir >/dev/null 2>&1; then
        if hooks_dir=$(git rev-parse --git-path hooks 2>/dev/null) \
            && mkdir -p "$hooks_dir"; then
            install_git_hook "$hooks_dir/pre-commit" 'exec substrate-engine hook changed-files-scan' || rc=1
            install_git_hook "$hooks_dir/pre-push" 'exec bash "$(git rev-parse --show-toplevel)/.substrate/push-gate.sh"' || rc=1
        else
            warn "effective Git hooks directory is unavailable"
            rc=1
        fi
    fi
    if [ -d .jj ]; then
        if command -v jj >/dev/null 2>&1; then
            # jj runs no hooks (jj#403): this alias + the harness mirrors are the
            # gates — bare `jj git push` stays open by construction
            if jj config set --repo aliases.push '["util", "exec", "--", "bash", "-c", "exec bash \"$(jj workspace root)/.substrate/gated-push.sh\" \"$@\"", "jj-push"]'; then
                success "jj push alias gated (jj push [args] runs the gate first)"
            else
                warn "jj push alias install failed"
                rc=1
            fi
        else
            warn ".jj present but jj not installed — push alias skipped"
            rc=1
        fi
    fi
    return "$rc"
}


install_templates() {
    local profiles=("$@") p d src dest
    for p in "${profiles[@]}"; do
        d=$(profile_dir "$p") || continue
        while IFS=$'\t' read -r src dest; do
            [ -n "$src" ] || continue
            repo_path_safe "$dest" "template $dest" || return 1
            if [ -e "$dest" ]; then
                info "template $dest exists — left untouched"
            else
                if mkdir -p "$(dirname "$dest")" && cp "$d/templates/$src" "$dest"; then
                    success "template installed: $dest"
                else
                    warn "template installation failed: $dest"
                    return 1
                fi
            fi
        done < <(jq -r '(.templates // [])[] | "\(.src)\t\(.dest)"' "$d/profile.json")
    done
}

install_recipe() {
    repo_path_safe justfile "gate recipe" || return 1
    repo_path_safe Makefile "gate target" || return 1
    if [ -f justfile ]; then
        if grep -qE 'substrate-engine gate|\.substrate/gate\.sh' justfile; then
            success "gate recipe wired (just gate)"
        elif grep -qE '^gate[ :]' justfile; then
            warn "justfile already owns a 'gate' recipe — point it at substrate-engine gate yourself (appending would redefine the recipe and break just entirely)"
            return 1
        else
            printf '\ngate *ARGS:\n    substrate-engine gate {{ARGS}}\n' >> justfile \
                || { warn "gate recipe write failed"; return 1; }
            success "gate recipe wired (just gate)"
        fi
    elif [ -f Makefile ]; then
        if grep -q 'substrate-engine gate' Makefile; then
            success "gate target wired (make gate)"
        elif grep -qE '^gate:' Makefile; then
            warn "Makefile already owns a 'gate' target — point it at substrate-engine gate yourself"
            return 1
        else
            printf '\ngate:\n\tsubstrate-engine gate\n' >> Makefile \
                || { warn "gate target write failed"; return 1; }
            success "gate target wired (make gate)"
        fi
    else
        printf 'gate *ARGS:\n    substrate-engine gate {{ARGS}}\n' > justfile \
            || { warn "gate recipe write failed"; return 1; }
        success "gate recipe wired (just gate)"
    fi
}

install_jj_workflow_doc() {
    if [ "${SUBSTRATE_RENDER_VCS:-}" != jj ] && [ ! -d .jj ]; then
        return 0
    fi
    repo_path_safe docs/jj-workflow.md "jj workflow documentation" || return 1
    if [ ! -f docs/jj-workflow.md ]; then
        if mkdir -p docs && cp "$KIT_ROOT/core/jj-workflow.md" docs/jj-workflow.md; then
            success "jj workflow doc installed: docs/jj-workflow.md"
        else
            warn "jj workflow documentation install failed"
            return 1
        fi
    fi
}

wire_jj_runtime() {
    [ -d .jj ] || return 0
    command -v jj >/dev/null 2>&1 || { warn ".jj present but jj not installed — jj wiring skipped"; return 1; }
    local trunk=main
    if jj bookmark list 2>/dev/null | grep -q '^master:' && ! jj bookmark list 2>/dev/null | grep -q '^main:'; then
        trunk=master
    fi
    jj config get aliases.tug >/dev/null 2>&1 \
        || jj config set --user aliases.tug '["bookmark", "advance", "--to", "@-"]'
    jj config set --repo experimental-advance-branches.enabled-branches "[\"$trunk\"]"
    if ! jj bookmark list 2>/dev/null | grep -q "^$trunk:"; then
        jj bookmark create "$trunk" -r @- 2>/dev/null \
            && success "trunk bookmark $trunk created at @-" \
            || warn "no $trunk bookmark yet — create it after the first commit: jj bookmark create $trunk -r @-"
    fi
    if jj bookmark list --all-remotes 2>/dev/null | grep -q "^$trunk@origin:"; then
        jj bookmark track "$trunk" --remote=origin 2>/dev/null || true
    fi
    success "jj tug wired ($trunk auto-advance; --repo config is machine-local, rerun init per clone)"
}

wire_jj() {
    install_jj_workflow_doc || return 1
    wire_jj_runtime
}

install_lsp_config() {
    local profiles=("$@") p d dirs=()
    repo_path_safe .omp/lsp.json "omp LSP configuration" || return 1
    if [ -f .omp/lsp.json ]; then
        info ".omp/lsp.json exists — left untouched (repo edits win)"
        return 0
    fi
    for p in "${profiles[@]}"; do
        d=$(profile_dir "$p") || continue
        dirs+=("$d/profile.json")
    done
    [ ${#dirs[@]} -gt 0 ] || return 0
    # Propagate optional fileTypes overrides (e.g. shell dotfiles omp's extension
    # matcher misses); bin/hint stay substrate-doctor metadata, never omp config.
    local merged
    merged=$(cat "${dirs[@]}" | jq -rs '
        [ .[] | (.lsp // {})
            | with_entries(.value |= ({fileTypes}
                | with_entries(select(.value != null and ((.value | length) > 0))))) ]
        | add // {}
        | to_entries | sort_by(.key) | from_entries') \
        || { warn ".omp/lsp.json build failed"; return 1; }
    [ "$(jq 'length' <<< "$merged")" -gt 0 ] || return 0
    mkdir -p .omp
    if jq -n --argjson s "$merged" \
        '{servers: ($s | map_values(. + {disabled: false})), idleTimeoutMs: 300000}' \
        > .omp/lsp.json; then
        success "omp LSP config seeded: .omp/lsp.json ($(jq -r 'keys | join(", ")' <<< "$merged"))"
    else
        warn ".omp/lsp.json write failed"
        return 1
    fi
}
