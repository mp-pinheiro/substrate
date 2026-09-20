#!/usr/bin/env bash
set -euo pipefail

event="${RELEASE_EVENT:-workflow_dispatch}"
requested="${RELEASE_CHANNEL:-}"
head_sha="${RELEASE_HEAD_SHA:?RELEASE_HEAD_SHA is required}"
mirror_repo="${RELEASE_MIRROR_REPO:-mp-pinheiro/substrate}"
version_file="${RELEASE_VERSION_FILE:-VERSION}"
today="${RELEASE_DATE:-$(date -u +%Y%m%d)}"
token="${RELEASE_MIRROR_TOKEN:-${MIRROR_TOKEN:-}}"
out_file="${RELEASE_OUTPUT:-${GITHUB_OUTPUT:-/dev/stdout}}"

exec 3>&1
die() { printf '::error::%s\n' "$1" >&3; exit 1; }
notice() { printf '::notice::%s\n' "$1" >&3; }

mirror_get() {
    local url=$1 response code
    response=$(curl -sS -o - -w '\n%{http_code}' \
        -H "Authorization: Bearer $token" \
        -H 'Accept: application/vnd.github+json' "$url" 2>/dev/null) \
        || die "mirror lookup could not reach $url — refusing to guess whether the tag exists"
    code=${response##*$'\n'}
    case "$code" in
        200) printf '%s' "${response%$'\n'*}" ;;
        404) return 44 ;;
        *) die "mirror lookup for $url returned HTTP $code — refusing to treat that as an absent tag" ;;
    esac
}

resolve_tag_target() {
    local want=$1 ref sha type rc
    if git rev-parse -q --verify "refs/tags/$want" >/dev/null 2>&1; then
        git rev-list -n1 "$want"
        return 0
    fi
    [ -n "$token" ] \
        || die "no mirror token available to resolve $want — refusing to publish without a tag-collision check"
    ref=$(mirror_get "https://api.github.com/repos/${mirror_repo}/git/ref/tags/$want") || rc=$?
    [ "${rc:-0}" -ne 44 ] || return 0
    sha=$(printf '%s' "$ref" | jq -r '.object.sha // empty')
    type=$(printf '%s' "$ref" | jq -r '.object.type // empty')
    [ -n "$sha" ] || die "mirror returned a tag ref for $want with no sha"
    if [ "$type" = tag ]; then
        ref=$(mirror_get "https://api.github.com/repos/${mirror_repo}/git/tags/$sha") \
            || die "annotated tag $want could not be dereferenced on the mirror"
        sha=$(printf '%s' "$ref" | jq -r '.object.sha // empty')
        [ -n "$sha" ] || die "annotated tag $want dereferenced to no commit"
    fi
    printf '%s' "$sha"
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
