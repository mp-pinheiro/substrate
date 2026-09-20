#!/usr/bin/env bash

mirror_repo="${RELEASE_MIRROR_REPO:-mp-pinheiro/substrate}"
mirror_token="${RELEASE_MIRROR_TOKEN:-${MIRROR_TOKEN:-}}"
mirror_timeout="${RELEASE_MIRROR_TIMEOUT:-30}"
MIRROR_CODE=000
MIRROR_BODY=""

exec 3>&1
die() { printf '::error::%s\n' "$1" >&3; exit 1; }
notice() { printf '::notice::%s\n' "$1" >&3; }

mirror_call() {
    local method=$1 url=$2 data=${3:-} raw
    if [ -n "$data" ]; then
        raw=$(curl -sS -o - -w '\n%{http_code}' --max-time "$mirror_timeout" -X "$method" \
            -H "Authorization: Bearer $mirror_token" -H 'Accept: application/vnd.github+json' \
            -d "$data" "$url" 2>/dev/null) \
            || die "mirror request could not reach $url — refusing to guess its outcome"
    else
        raw=$(curl -sS -o - -w '\n%{http_code}' --max-time "$mirror_timeout" -X "$method" \
            -H "Authorization: Bearer $mirror_token" -H 'Accept: application/vnd.github+json' \
            "$url" 2>/dev/null) \
            || die "mirror request could not reach $url — refusing to guess its outcome"
    fi
    MIRROR_CODE=${raw##*$'\n'}
    MIRROR_BODY=${raw%$'\n'*}
}

mirror_get() {
    local url=$1
    mirror_call GET "$url"
    case "$MIRROR_CODE" in
        200) printf '%s' "$MIRROR_BODY" ;;
        404) return 44 ;;
        *) die "mirror lookup for $url returned HTTP $MIRROR_CODE — refusing to treat that as an absent tag" ;;
    esac
}

mirror_tag_commit() {
    local want=$1 ref sha type rc
    [ -n "$mirror_token" ] \
        || die "no mirror token available to resolve $want — refusing to publish without a tag-collision check"
    ref=$(mirror_get "https://api.github.com/repos/${mirror_repo}/git/ref/tags/$want") || rc=$?
    case "${rc:-0}" in
        0) ;;
        44) return 0 ;;
        *) exit "$rc" ;;
    esac
    sha=$(printf '%s' "$ref" | jq -r '.object.sha // empty')
    type=$(printf '%s' "$ref" | jq -r '.object.type // empty')
    [ -n "$sha" ] || die "mirror returned a tag ref for $want with no sha"
    if [ "$type" = tag ]; then
        ref=$(mirror_get "https://api.github.com/repos/${mirror_repo}/git/tags/$sha") || exit $?
        sha=$(printf '%s' "$ref" | jq -r '.object.sha // empty')
        [ -n "$sha" ] || die "annotated tag $want dereferenced to no commit"
    fi
    printf '%s' "$sha"
}
