#!/usr/bin/env bash
set -euo pipefail

event="${RELEASE_EVENT:-workflow_dispatch}"
requested="${RELEASE_CHANNEL:-}"
head_sha="${RELEASE_HEAD_SHA:?RELEASE_HEAD_SHA is required}"
mirror_repo="${RELEASE_MIRROR_REPO:-mp-pinheiro/substrate}"
version_file="${RELEASE_VERSION_FILE:-VERSION}"
today="${RELEASE_DATE:-$(date -u +%Y%m%d)}"

resolve_tag_target() {
    local want=$1 ref sha=""
    if git rev-parse -q --verify "refs/tags/$want" >/dev/null 2>&1; then
        git rev-list -n1 "$want"
        return 0
    fi
    [ -n "${RELEASE_MIRROR_TOKEN:-}" ] || { printf ''; return 0; }
    ref=$(curl -sS -H "Authorization: Bearer $RELEASE_MIRROR_TOKEN" \
        "https://api.github.com/repos/${mirror_repo}/git/ref/tags/$want" 2>/dev/null) || ref=""
    sha=$(printf '%s' "$ref" | jq -r '.object.sha // empty' 2>/dev/null) || sha=""
    if [ -n "$sha" ] && [ "$(printf '%s' "$ref" | jq -r '.object.type // empty')" = tag ]; then
        sha=$(curl -sS -H "Authorization: Bearer $RELEASE_MIRROR_TOKEN" \
            "https://api.github.com/repos/${mirror_repo}/git/tags/$sha" 2>/dev/null \
            | jq -r '.object.sha // empty') || sha=""
    fi
    printf '%s' "$sha"
}

base=$(cat "$version_file" 2>/dev/null) || base=
[ -n "$base" ] || { echo "::error::$version_file is missing or empty — refusing to resolve a release identity" >&2; exit 1; }

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
        echo "::notice::$tag was already published today at $existing — nothing to cut" >&2
        skip=true
    else
        echo "::error::$tag already points at $existing; republishing it from $head_sha would overwrite its artifacts. Bump $version_file for the next stable, or wait for tomorrow's nightly date." >&2
        exit 1
    fi
elif [ -n "$existing" ]; then
    echo "::notice::$tag already exists at this revision — resuming publication for it" >&2
fi

printf 'base=%s\n' "$base"
printf 'nightlybase=%s\n' "$nightly_base"
printf 'version=%s\n' "$version"
printf 'channel=%s\n' "$channel"
printf 'prerelease=%s\n' "$prerelease"
printf 'tag=%s\n' "$tag"
printf 'skip=%s\n' "$skip"
