scratch_repo_init() {
    local dir="$1" profile="${2:-shell}"
    mkdir -p "$dir" || { printf 'scratch_repo_init: cannot create %s\n' "$dir" >&2; return 1; }
    cd "$dir" || return 1
    git init -q -b main
    git config user.name substrate
    git config user.email substrate@localhost
    export SUBSTRATE_VENDOR_FROM_WORKTREE=1
    "$KIT_ROOT/bin/substrate" init --profile "$profile" --vcs git >/dev/null 2>&1 \
        || { printf 'scratch_repo_init: substrate init failed\n' >&2; return 1; }
}
