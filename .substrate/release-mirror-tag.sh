#!/usr/bin/env bash
set -euo pipefail

lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=core/release-mirror-lib.sh
. "$lib_dir/release-mirror-lib.sh"

tag="${RELEASE_TAG:?RELEASE_TAG is required}"
head_sha="${RELEASE_HEAD_SHA:?RELEASE_HEAD_SHA is required}"
waits="${RELEASE_MIRROR_WAITS:-0 10 20 30 60 60 120}"

[ -n "$mirror_token" ] || die "no mirror token available — refusing to tag the mirror unauthenticated"

request_sync() {
    local api="${GITHUB_API_URL:-}" slug="${GITHUB_REPOSITORY:-}" code
    [ -n "$api" ] && [ -n "$slug" ] || return 0
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time "$mirror_timeout" -X POST \
        -H "Authorization: token ${GITHUB_TOKEN:-}" \
        "$api/repos/$slug/push_mirrors-sync" 2>/dev/null) || code=000
    case "$code" in
        200|201|204) notice "requested an immediate push-mirror sync" ;;
        *) notice "could not trigger a push-mirror sync (HTTP $code) — waiting for the scheduled one" ;;
    esac
}

await_revision() {
    local delay
    for delay in $waits; do
        [ "$delay" = 0 ] || sleep "$delay"
        mirror_try GET "https://api.github.com/repos/${mirror_repo}/commits/$head_sha"
        [ "$MIRROR_CODE" = 200 ] && return 0
    done
    die "$head_sha has not reached the GitHub mirror (HTTP $MIRROR_CODE) — the Forgejo release is published; re-dispatch once the mirror carries the revision"
}

request_sync
await_revision

mirror_call POST "https://api.github.com/repos/${mirror_repo}/git/refs" \
    "$(jq -n --arg r "refs/tags/$tag" --arg s "$head_sha" '{ref:$r,sha:$s}')"
case "$MIRROR_CODE" in
    201)
        notice "created $tag on the mirror at $head_sha" ;;
    422)
        existing=$(mirror_tag_commit "$tag")
        [ -n "$existing" ] \
            || die "the mirror rejected $tag as existing but reports no such tag — refusing to guess"
        [ "$existing" = "$head_sha" ] \
            || die "$tag already exists on the mirror at $existing, not $head_sha"
        notice "$tag already present on the mirror at the released revision" ;;
    *)
        die "could not create $tag on the mirror (HTTP $MIRROR_CODE): $(printf '%s' "$MIRROR_BODY" | head -c 200)" ;;
esac
