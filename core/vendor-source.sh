#!/usr/bin/env bash
# Vendoring copies $KIT_ROOT/{core,profiles,skills,agents,VERSION,engine.json} into consumers
# verbatim, so the kit checkout must already be published — otherwise a maintainer's unpushed work
# lands in every repo that runs `substrate update`. The kit vendoring into itself is exempt: that
# loop is what keeps .substrate in sync with core/, and 80-vendor-drift requires it.
VENDOR_SOURCE_PATHS=(core profiles skills agents VERSION engine.json)
VENDOR_KIT_REVISION=worktree
VENDOR_KIT_SOURCE=worktree

guard_vendor_source() {
    local from_worktree="$1" kit
    VENDOR_KIT_REVISION=worktree
    VENDOR_KIT_SOURCE=worktree
    [ "$from_worktree" -ne 1 ] || return 0
    [ "${SUBSTRATE_VENDOR_FROM_WORKTREE:-}" != 1 ] || return 0
    kit=$(cd "$KIT_ROOT" && pwd -P) || die "cannot resolve the kit root at $KIT_ROOT"
    [ "$(pwd -P)" != "$kit" ] || return 0
    if [ -d "$KIT_ROOT/.jj" ]; then
        command -v jj >/dev/null 2>&1 \
            || die "kit checkout at $KIT_ROOT is a Jujutsu repo but jj is not installed — pass --from-worktree"
        guard_vendor_source_jj "$kit"
    elif [ -d "$KIT_ROOT/.git" ]; then
        guard_vendor_source_git "$kit"
    else
        die "kit checkout at $KIT_ROOT is not a repository root — pass --from-worktree to vendor from it anyway"
    fi
    VENDOR_KIT_SOURCE=trunk
}

guard_vendor_source_jj() {
    local kit="$1" dirty trunk rev root
    root=$(cd "$kit" && jj --no-pager workspace root 2>/dev/null) \
        || die "cannot resolve the Jujutsu workspace at $kit — pass --from-worktree"
    [ "$root" = "$kit" ] || die "kit checkout at $kit is not a Jujutsu workspace root — pass --from-worktree"
    dirty=$(cd "$kit" && jj --no-pager diff -r @ -T 'path ++ "\n"' -- "${VENDOR_SOURCE_PATHS[@]}" 2>/dev/null) \
        || die "cannot inspect the kit working copy at $kit — pass --from-worktree to vendor from it anyway"
    [ -z "$dirty" ] \
        || die "kit worktree has uncommitted vendor sources — commit and push, or pass --from-worktree: $(printf '%s' "$dirty" | tr '\n' ' ')"
    for trunk in main master; do
        (cd "$kit" && jj --no-pager log -r "$trunk@origin" --no-graph -T 'commit_id') >/dev/null 2>&1 && break
        trunk=""
    done
    [ -n "$trunk" ] \
        || die "cannot resolve main@origin or master@origin in the kit checkout — push the kit, or pass --from-worktree"
    rev=$(cd "$kit" && jj --no-pager log -r '@-' --no-graph -T 'commit_id' 2>/dev/null) \
        || die "cannot resolve the kit revision at $kit — pass --from-worktree"
    [ -n "$(cd "$kit" && jj --no-pager log -r "@- & ::($trunk@origin)" --no-graph -T 'commit_id' 2>/dev/null)" ] \
        || die "kit revision ${rev:0:12} is not contained in $trunk@origin — push the kit, or pass --from-worktree"
    VENDOR_KIT_REVISION="$rev"
}

guard_vendor_source_git() {
    local kit="$1" dirty trunk rev root
    root=$(git -C "$kit" rev-parse --show-toplevel 2>/dev/null) \
        || die "cannot inspect the kit repository at $kit — pass --from-worktree"
    [ "$root" = "$kit" ] || die "kit checkout at $kit is not a repository root — pass --from-worktree"
    dirty=$(git -C "$kit" status --porcelain=v1 --untracked-files=all -- "${VENDOR_SOURCE_PATHS[@]}" 2>/dev/null) \
        || die "cannot inspect the kit working copy at $kit — pass --from-worktree to vendor from it anyway"
    [ -z "$dirty" ] \
        || die "kit worktree has uncommitted vendor sources — commit and push, or pass --from-worktree: $(printf '%s' "$dirty" | tr '\n' ' ')"
    for trunk in main master; do
        git -C "$kit" rev-parse --verify --quiet "origin/$trunk" >/dev/null && break
        trunk=""
    done
    [ -n "$trunk" ] \
        || die "cannot resolve origin/main or origin/master in the kit checkout — push the kit, or pass --from-worktree"
    rev=$(git -C "$kit" rev-parse --verify HEAD 2>/dev/null) \
        || die "cannot resolve the kit revision at $kit — pass --from-worktree"
    git -C "$kit" merge-base --is-ancestor HEAD "origin/$trunk" \
        || die "kit revision ${rev:0:12} is not contained in origin/$trunk — push the kit, or pass --from-worktree"
    VENDOR_KIT_REVISION="$rev"
}

write_vendor_provenance() {
    jq -n --arg kitRevision "$VENDOR_KIT_REVISION" --arg source "$VENDOR_KIT_SOURCE" \
        --arg version "$(cat "$KIT_ROOT/VERSION")" \
        '{kitRevision:$kitRevision,source:$source,version:$version}' > "$1/vendor.json"
}

report_vendor_staleness() {
    local vendored
    vendored=$(jq -r '.kitRevision // "unknown"' .substrate/vendor.json 2>/dev/null) || vendored=unknown
    [ -n "$vendored" ] || vendored=unknown
    if [ "$vendored" = "$VENDOR_KIT_REVISION" ]; then
        info "vendored kit revision ${vendored:0:12} — current"
    else
        info "vendored kit revision ${vendored:0:12} — kit at ${VENDOR_KIT_REVISION:0:12}"
    fi
}
