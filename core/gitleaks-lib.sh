#!/usr/bin/env bash
# Shared Gitleaks scope construction for the cheap pending scan and cached deep scan.

synthetic_git_tip() {
    local index tree tip rc parent=()
    index=$(mktemp) || return 1
    rm -f "$index"
    (
        export GIT_INDEX_FILE="$index"
        if git rev-parse --verify HEAD >/dev/null 2>&1; then
            git read-tree HEAD || exit 1
            parent=(-p HEAD)
        else
            git read-tree --empty || exit 1
        fi
        git add -A -- . || exit 1
        tree=$(git write-tree) || exit 1
        export GIT_AUTHOR_NAME=substrate GIT_AUTHOR_EMAIL=substrate@localhost
        export GIT_COMMITTER_NAME=substrate GIT_COMMITTER_EMAIL=substrate@localhost
        tip=$(printf 'substrate pending scan\n' | git commit-tree "$tree" "${parent[@]}") || exit 1
        printf '%s\n' "$tip"
    )
    rc=$?
    rm -f "$index"
    return "$rc"
}

pending_git_tip() {
    if [ -e .jj ] && command -v jj >/dev/null 2>&1; then
        jj log -r @ --no-graph -T 'commit_id' 2>/dev/null
    else
        synthetic_git_tip
    fi
}

pending_gitleaks_log_opts() {
    local tip oid opts
    tip=$(pending_git_tip) || return 1
    [ -n "$tip" ] || return 1
    opts="$tip"
    while IFS= read -r oid; do
        [ -n "$oid" ] || continue
        opts="$opts ^$oid"
    done < <(git for-each-ref --format='%(objectname)' refs/remotes | LC_ALL=C sort -u)
    printf '%s\n' "$opts"
}

gitleaks_config_hash() {
    local config=.gitleaks.toml
    if [ -f "$config" ]; then
        sha256sum "$config" | cut -d ' ' -f 1
    else
        printf 'builtin\n'
    fi
}

gitleaks_deep_key() {
    local refs_hash version config_hash
    refs_hash=$({
        git for-each-ref --format='%(refname) %(objectname)' refs/heads refs/tags refs/remotes
        git rev-parse HEAD 2>/dev/null || true
    } | LC_ALL=C sort -u | sha256sum | cut -d ' ' -f 1) || return 1
    version=$(gitleaks version 2>/dev/null | tr -d '\r\n') || return 1
    config_hash=$(gitleaks_config_hash) || return 1
    printf '%s\n' "$refs_hash:$version:$config_hash" | sha256sum | cut -d ' ' -f 1
}
