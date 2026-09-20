#!/usr/bin/env bash
set -euo pipefail

lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=core/release-mirror-lib.sh
. "$lib_dir/release-mirror-lib.sh"

event="${RELEASE_EVENT:-workflow_dispatch}"
requested="${RELEASE_CHANNEL:-}"
head_sha="${RELEASE_HEAD_SHA:?RELEASE_HEAD_SHA is required}"
version_file="${RELEASE_VERSION_FILE:-VERSION}"
today="${RELEASE_DATE:-$(date -u +%Y%m%d)}"
out_file="${RELEASE_OUTPUT:-${GITHUB_OUTPUT:-/dev/stdout}}"

resolve_tag_target() {
    local want=$1
    if git rev-parse -q --verify "refs/tags/$want" >/dev/null 2>&1; then
        git rev-list -n1 "$want"
        return 0
    fi
    mirror_tag_commit "$want"
}

base=$(cat "$version_file" 2>/dev/null) || base=
[ -n "$base" ] || die "$version_file is missing or empty — refusing to resolve a release identity"

released_sha=$(resolve_tag_target "v$base")
nightly_base="$base"
if [ -n "$released_sha" ]; then
    IFS=. read -r major minor _patch <<< "$base"
    nightly_base="${major}.$((minor + 1)).0"
fi

if [ "$event" = schedule ] || [ "$requested" = nightly ]; then
    version="${nightly_base}-nightly.${today}"
    channel=nightly
    prerelease=true
else
    version="$base"
    channel=release
    prerelease=false
fi

tag="v$version"
existing=$(resolve_tag_target "$tag")
skip=false
if [ -n "$existing" ] && [ "$existing" != "$head_sha" ]; then
    if [ "$event" = schedule ]; then
        notice "$tag was already published today at $existing — nothing to cut"
        skip=true
    else
        die "$tag already points at $existing; republishing it from $head_sha would overwrite its artifacts. Bump $version_file for the next stable, or wait for tomorrow's nightly date."
    fi
elif [ -n "$existing" ]; then
    notice "$tag already exists at this revision — resuming publication for it"
fi

{
    printf 'base=%s\n' "$base"
    printf 'nightlybase=%s\n' "$nightly_base"
    printf 'version=%s\n' "$version"
    printf 'channel=%s\n' "$channel"
    printf 'prerelease=%s\n' "$prerelease"
    printf 'tag=%s\n' "$tag"
    printf 'skip=%s\n' "$skip"
} >> "$out_file"
