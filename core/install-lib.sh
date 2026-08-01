#!/usr/bin/env bash
# Installer library sourced by bin/substrate: everything cmd_init arms in a
# repo (templates, CI, hooks, harnesses, VCS gates, skills, recipes, jj).
# Requires: KIT_ROOT, info/success/warn/die, profile_dir from the caller.

install_ci() {
    local profiles=("$@") p d lines=() l
    [ -f .github/workflows/substrate-gate.yml ] && { info "CI workflow exists — left untouched"; return 0; }
    for p in "${profiles[@]}"; do
        d=$(profile_dir "$p") || continue
        while IFS= read -r l; do
            [ -n "$l" ] && lines+=("$l")
        done < <(jq -r '(.ci // [])[]' "$d/profile.json")
    done
    mkdir -p .github/workflows
    local out=.github/workflows/substrate-gate.yml line trimmed
    : > "$out"
    while IFS= read -r line; do
        trimmed="${line#"${line%%[![:space:]]*}"}"
        if [ "$trimmed" = "# substrate:profile-toolchain" ]; then
            for l in ${lines[@]+"${lines[@]}"}; do
                printf '          %s\n' "$l" >> "$out"
            done
        else
            printf '%s\n' "$line" >> "$out"
        fi
    done < "$KIT_ROOT/core/ci/github-gate.yml"
    success "CI workflow installed: $out"
    if [ ! -f .github/workflows/substrate-report.yml ]; then
        cp "$KIT_ROOT/core/ci/github-report.yml" .github/workflows/substrate-report.yml \
            && success "report schedule installed: .github/workflows/substrate-report.yml" \
            || warn "report schedule install failed"
    fi
}

install_hooks_config() {
    local template="$KIT_ROOT/core/claude-hooks.json" settings=.claude/settings.json merged
    mkdir -p .claude
    if [ -f "$settings" ] && jq -e . "$settings" >/dev/null 2>&1; then
        # hook arrays concatenate (deep merge would drop repo-owned hooks) yet
        # stay idempotent: .substrate/ groups are dropped before re-appending
        if ! merged=$(jq --argjson extra "$(cat "$template")" '
            def keep: map(select([.hooks[]?.command // ""] | any(test("\\.substrate/hooks/")) | not));
            .hooks.PreToolUse = (((.hooks.PreToolUse // []) | keep) + ($extra.hooks.PreToolUse // []))
            | .hooks.PostToolUse = (((.hooks.PostToolUse // []) | keep) + ($extra.hooks.PostToolUse // []))
        ' "$settings"); then
            warn "Claude settings merge failed — $settings left untouched"
            return 1
        fi
        if ! printf '%s\n' "$merged" > "$settings" 2>/dev/null; then
            warn "$settings is not writable (locked?) — chmod u+w it, rerun init, or merge manually from $template"
            return 1
        fi
    elif [ -f "$settings" ]; then
        warn "$settings exists but is not valid JSON — left untouched; merge the hooks manually from $template"
        return 1
    else
        cp "$template" "$settings" || { warn "failed to write $settings"; return 1; }
    fi
    success "Claude hooks wired in $settings"
    mkdir -p .omp/extensions
    cp "$KIT_ROOT/core/omp/substrate-quality.ts" .omp/extensions/ || { warn "omp extension install failed"; return 1; }
    success "omp extension installed: .omp/extensions/substrate-quality.ts"
}

install_user_harness() {
    if [ "${SUBSTRATE_NO_USER_HARNESS:-}" = "1" ]; then
        info "user harness skipped (SUBSTRATE_NO_USER_HARNESS=1)"
        return 0
    fi
    local rc=0
    # agent-level only — ~/.omp/profiles/* must never be touched by this installer
    if mkdir -p "$HOME/.omp/agent/extensions" 2>/dev/null \
        && cp "$KIT_ROOT/core/omp/substrate-quality.ts" "$HOME/.omp/agent/extensions/substrate-quality.ts" 2>/dev/null; then
        success "user-level omp extension: ~/.omp/agent/extensions/substrate-quality.ts"
    else
        warn "user-level omp extension install failed — sessions rooted outside substrate repos run unguarded"
        rc=1
    fi

    if mkdir -p "$HOME/.claude/hooks" 2>/dev/null \
        && cp "$KIT_ROOT/core/substrate-launch.sh" "$HOME/.claude/hooks/substrate-launch.sh" 2>/dev/null \
        && chmod +x "$HOME/.claude/hooks/substrate-launch.sh" 2>/dev/null; then
        success "user-level Claude launcher: ~/.claude/hooks/substrate-launch.sh"
    else
        warn "user-level Claude launcher install failed"
        return 1
    fi

    local template="$KIT_ROOT/core/claude-hooks-user.json" settings="$HOME/.claude/settings.json" merged mode=""
    if [ -f "$settings" ] && jq -e . "$settings" >/dev/null 2>&1; then
        # drop substrate-launch groups, re-append (idempotent, same shape as install_hooks_config)
        if ! merged=$(jq --argjson extra "$(cat "$template")" '
            def keep: map(select([.hooks[]?.command // ""] | any(test("substrate-launch")) | not));
            .hooks.PreToolUse = (((.hooks.PreToolUse // []) | keep) + ($extra.hooks.PreToolUse // []))
            | .hooks.PostToolUse = (((.hooks.PostToolUse // []) | keep) + ($extra.hooks.PostToolUse // []))
        ' "$settings"); then
            warn "user Claude settings merge failed — $settings left untouched"
            return 1
        fi
        mode=$(stat -c '%a' "$settings" 2>/dev/null) || mode=""
        # stage-and-rename: never truncate the user's live Claude config in place
        local tmp
        if ! tmp=$(mktemp "$settings.XXXXXX" 2>/dev/null); then
            warn "cannot stage next to $settings — merge the hooks manually from $template"
            return 1
        fi
        printf '%s\n' "$merged" > "$tmp" || { rm -f "$tmp"; warn "staging write failed for $settings"; return 1; }
        [ -n "$mode" ] && chmod "$mode" "$tmp" 2>/dev/null
        if ! mv -f "$tmp" "$settings" 2>/dev/null; then
            rm -f "$tmp"
            warn "$settings is not replaceable — merge the hooks manually from $template"
            return 1
        fi
    elif [ -f "$settings" ]; then
        warn "$settings exists but is not valid JSON — left untouched; merge manually from $template"
        return 1
    else
        cp "$template" "$settings" || { warn "failed to write $settings"; return 1; }
    fi
    success "user-level Claude hooks wired in $settings"
    return "$rc"
}

install_git_hook() {
    local path="$1" body="$2" name
    name=$(basename "$path")
    if [ -f "$path" ] && ! grep -q '^# substrate-managed$' "$path"; then
        warn "$name exists and is not substrate-managed — left untouched"
        return 0
    fi
    if printf '#!/usr/bin/env bash\n# substrate-managed\n%s\n' "$body" > "$path" && chmod +x "$path"; then
        success "git $name hook installed"
    else
        warn "git $name hook install failed"
        return 1
    fi
}

install_vcs_hooks() {
    local rc=0 hooks_dir
    if [ -d .git ]; then
        if [ -n "$(git config --get core.hooksPath 2>/dev/null)" ]; then
            warn "core.hooksPath is set — install substrate hooks there yourself"
        else
            hooks_dir=$(git rev-parse --git-path hooks 2>/dev/null) || hooks_dir=.git/hooks
            mkdir -p "$hooks_dir"
            install_git_hook "$hooks_dir/pre-commit" 'exec bash "$(git rev-parse --show-toplevel)/.substrate/hooks/changed-files-scan.sh"' || rc=1
            install_git_hook "$hooks_dir/pre-push" 'exec bash "$(git rev-parse --show-toplevel)/.substrate/gate.sh"' || rc=1
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

install_skills() {
    local s name dest
    [ -d "$KIT_ROOT/skills" ] || return 0
    if ! mkdir -p .claude/skills 2>/dev/null; then
        warn ".claude/skills is not a directory — skills not installed; fix the path and rerun init"
        return 1
    fi
    for s in "$KIT_ROOT"/skills/*/; do
        [ -d "$s" ] || continue
        name=$(basename "$s")
        dest=".claude/skills/$name"
        if [ -e "$dest" ]; then
            info "skill $name exists — left untouched"
        elif cp -R "$s" "$dest" 2>/dev/null; then
            success "skill installed: $dest"
        else
            warn "skill $name install failed — is .claude/skills writable?"
            return 1
        fi
    done
}

install_templates() {
    local profiles=("$@") p d src dest
    for p in "${profiles[@]}"; do
        d=$(profile_dir "$p") || continue
        while IFS=$'\t' read -r src dest; do
            [ -n "$src" ] || continue
            if [ -e "$dest" ]; then
                info "template $dest exists — left untouched"
            else
                mkdir -p "$(dirname "$dest")"
                cp "$d/templates/$src" "$dest"
                success "template installed: $dest"
            fi
        done < <(jq -r '(.templates // [])[] | "\(.src)\t\(.dest)"' "$d/profile.json")
    done
}

install_recipe() {
    if [ -f justfile ]; then
        if grep -q '.substrate/gate.sh' justfile; then
            success "gate recipe wired (just gate)"
        elif grep -qE '^gate[ :]' justfile; then
            warn "justfile already owns a 'gate' recipe — point it at .substrate/gate.sh yourself (appending would redefine the recipe and break just entirely)"
            return 1
        else
            printf '\ngate *ARGS:\n    .substrate/gate.sh {{ARGS}}\n' >> justfile
            success "gate recipe wired (just gate)"
        fi
    elif [ -f Makefile ]; then
        if grep -q '.substrate/gate.sh' Makefile; then
            success "gate target wired (make gate)"
        elif grep -qE '^gate:' Makefile; then
            warn "Makefile already owns a 'gate' target — point it at .substrate/gate.sh yourself"
            return 1
        else
            printf '\ngate:\n\t.substrate/gate.sh\n' >> Makefile
            success "gate target wired (make gate)"
        fi
    else
        printf 'gate *ARGS:\n    .substrate/gate.sh {{ARGS}}\n' > justfile
        success "gate recipe wired (just gate)"
    fi
}

wire_jj() {
    [ -d .jj ] || return 0
    command -v jj >/dev/null 2>&1 || { warn ".jj present but jj not installed — jj wiring skipped"; return 1; }
    if [ ! -f docs/jj-workflow.md ]; then
        mkdir -p docs
        cp "$KIT_ROOT/core/jj-workflow.md" docs/jj-workflow.md && success "jj workflow doc installed: docs/jj-workflow.md"
    fi
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

install_lsp_config() {
    local profiles=("$@") p d k keys=()
    if [ -f .omp/lsp.json ]; then
        info ".omp/lsp.json exists — left untouched (repo edits win)"
        return 0
    fi
    for p in "${profiles[@]}"; do
        d=$(profile_dir "$p") || continue
        while IFS= read -r k; do
            [ -n "$k" ] && keys+=("$k")
        done < <(jq -r '(.lsp // {}) | keys[]' "$d/profile.json")
    done
    [ ${#keys[@]} -eq 0 ] && return 0
    mkdir -p .omp
    if printf '%s\n' "${keys[@]}" | jq -Rn \
        '{servers: ([inputs] | unique | map({(.): {disabled: false}}) | add), idleTimeoutMs: 300000}' \
        > .omp/lsp.json; then
        success "omp LSP config seeded: .omp/lsp.json (${keys[*]})"
    else
        warn ".omp/lsp.json write failed"
        return 1
    fi
}
