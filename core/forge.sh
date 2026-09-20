#!/usr/bin/env bash
set -uo pipefail

die() { printf 'forge: %s\n' "$1" >&2; exit "${2:-1}"; }

forge_curl() {
    curl -sSf -H "Authorization: token $token" "$@"
}

resolve_host() {
    api=${SUBSTRATE_FORGE_API:-${GITHUB_API_URL:-}}
    slug=${SUBSTRATE_FORGE_SLUG:-${GITHUB_REPOSITORY:-}}
    if [ -n "$api" ] && [ -n "$slug" ]; then
        return 0
    fi
    local url rest host
    url=$(git remote get-url origin 2>/dev/null) || die "cannot resolve origin remote (no GITHUB_API_URL/GITHUB_REPOSITORY either)" 3
    case "$url" in
        git@*:*)
            rest=${url#git@}
            host=${rest%%:*}
            slug=${rest#*:}
            ;;
        ssh://*)
            rest=${url#ssh://}
            rest=${rest#*@}
            host=${rest%%/*}
            slug=${rest#*/}
            ;;
        *://*)
            rest=${url#*://}
            rest=${rest#*@}
            host=${rest%%/*}
            slug=${rest#*/}
            ;;
        *)
            die "unrecognized origin remote: $url" 3
            ;;
    esac
    slug=${slug%.git}
    if [ "$host" = github.com ]; then
        api=https://api.github.com
    else
        api="https://$host/api/v1"
    fi
}

resolve_token() {
    token=${SUBSTRATE_FORGE_TOKEN:-${GITHUB_TOKEN:-${GH_TOKEN:-}}}
    if [ -z "$token" ] && [ "$api" = "https://api.github.com" ]; then
        token=$(gh auth token 2>/dev/null) || true
    fi
    [ -n "$token" ] || die "no usable token — set GITHUB_TOKEN/GH_TOKEN or run 'gh auth login'" 3
    export GH_TOKEN="$token"
}

github_upsert_issue() {
    local label=$1 title=$2 body_file=$3 n
    gh label create "$label" --repo "$slug" --force --description "substrate maintenance queue" --color 5319e7 >/dev/null \
        || die "gh label create failed" 1
    n=$(gh api "repos/$slug/issues?labels=$label&state=open" --jq '.[0].number // empty') \
        || die "gh api issue lookup failed" 1
    if [ -n "$n" ]; then
        gh issue edit "$n" --repo "$slug" --title "$title" --body-file "$body_file" >/dev/null \
            || die "gh issue edit failed" 1
    else
        n=$(gh issue create --repo "$slug" --title "$title" --label "$label" --body-file "$body_file" \
            | grep -oE '[0-9]+$') \
            || die "gh issue create failed" 1
    fi
    printf '%s\n' "$n"
}

github_open_issue() {
    gh api "repos/$slug/issues?labels=$1&state=open" --jq '.[0].number // empty' \
        || die "gh api issue lookup failed" 1
}

github_issue_json() {
    gh api "repos/$slug/issues/$1" || die "gh api issue fetch failed" 1
}

github_ref_status() {
    gh api "repos/$slug/commits/$1/check-runs" --jq \
        '[.check_runs[].conclusion] | if length == 0 then "" elif all(. == "success" or . == "skipped" or . == "neutral") then "success" else "failure" end' \
        || die "gh api check-runs lookup failed" 1
}

forgejo_curl() {
    curl -sSf -H "Authorization: token $token" -H "Content-Type: application/json" "$@"
}

forgejo_ensure_label() {
    local label=$1 id
    id=$(forgejo_curl "$api/repos/$slug/labels" | jq -r --arg n "$label" '.[] | select(.name == $n) | .id' | head -n1) \
        || die "forgejo label lookup failed" 1
    if [ -z "$id" ]; then
        id=$(forgejo_curl -X POST "$api/repos/$slug/labels" \
            -d "$(jq -n --arg n "$label" '{name: $n, color: "5319e7", description: "substrate maintenance queue"}')" \
            | jq -r '.id') \
            || die "forgejo label create failed" 1
    fi
    printf '%s\n' "$id"
}

forgejo_open_issue() {
    forgejo_curl "$api/repos/$slug/issues?state=open&labels=$1&limit=1" | jq -r '.[0].number // empty' \
        || die "forgejo issue lookup failed" 1
}

forgejo_upsert_issue() {
    local label=$1 title=$2 body_file=$3 label_id n body
    label_id=$(forgejo_ensure_label "$label")
    n=$(forgejo_open_issue "$label")
    body=$(jq -Rs '.' < "$body_file") || die "cannot read body file: $body_file" 1
    if [ -n "$n" ]; then
        forgejo_curl -X PATCH "$api/repos/$slug/issues/$n" \
            -d "$(jq -n --arg t "$title" --argjson b "$body" '{title: $t, body: $b}')" >/dev/null \
            || die "forgejo issue update failed" 1
    else
        n=$(forgejo_curl -X POST "$api/repos/$slug/issues" \
            -d "$(jq -n --arg t "$title" --argjson b "$body" --argjson lid "$label_id" '{title: $t, body: $b, labels: [$lid]}')" \
            | jq -r '.number') \
            || die "forgejo issue create failed" 1
    fi
    printf '%s\n' "$n"
}

forgejo_issue_json() {
    forgejo_curl "$api/repos/$slug/issues/$1" || die "forgejo issue fetch failed" 1
}

forgejo_ref_status() {
    local prefix="${SUBSTRATE_STATUS_CONTEXT:-substrate-gate}"
    forgejo_curl "$api/repos/$slug/commits/$1/statuses?limit=100" \
        | jq -r --arg p "$prefix" '
            [.[] | select((.context // "") | startswith($p))]
            | group_by(.context)
            | map(max_by(.updated_at // .created_at // ""))
            | map(.status)
            | if length == 0 then ""
              elif any(. == "failure" or . == "error") then "failure"
              elif any(. == "pending") then "pending"
              elif any(. == "success") then "success"
              else "skipped" end' \
        || die "forgejo status lookup failed" 1
}

dry_run() {
    [ -n "${SUBSTRATE_FORGE_DRYRUN:-}" ]
}

release_id_for_tag() {
    forge_curl "$api/repos/$slug/releases/tags/$1" 2>/dev/null | jq -r '.id // empty'
}

create_release() {
    local tag=$1 name=$2 prerelease=$3 notes_file=$4 target=$5 payload id response code
    [ -f "$notes_file" ] || die "notes file not found: $notes_file" 1
    if dry_run; then
        printf 'DRYRUN create-release host=%s slug=%s tag=%s prerelease=%s target=%s notes=%s bytes\n' \
            "$api" "$slug" "$tag" "$prerelease" "${target:-<none>}" "$(wc -c < "$notes_file")" >&2
        printf 'dryrun-%s\n' "$tag"
        return 0
    fi
    id=$(release_id_for_tag "$tag")
    if [ -n "$id" ]; then
        printf '%s\n' "$id"
        return 0
    fi
    payload=$(jq -n --arg tag "$tag" --arg name "$name" --arg target "$target" \
        --argjson prerelease "$prerelease" --rawfile body "$notes_file" \
        '{tag_name:$tag,name:$name,body:$body,prerelease:$prerelease,draft:false}
         + (if $target == "" then {} else {target_commitish:$target} end)') \
        || die "release payload build failed" 1
    response=$(mktemp)
    code=$(printf '%s' "$payload" | curl -sS -o "$response" -w '%{http_code}' \
        -H "Authorization: token $token" -H "Content-Type: application/json" \
        -X POST --data-binary @- "$api/repos/$slug/releases")
    id=$(jq -r '.id // empty' "$response" 2>/dev/null)
    if [ -z "$id" ]; then
        printf 'forge: release creation failed on %s/%s (HTTP %s): %s\n' \
            "$api" "$slug" "$code" "$(head -c 300 "$response")" >&2
        rm -f "$response"
        exit 1
    fi
    rm -f "$response"
    printf '%s\n' "$id"
}

drop_existing_asset() {
    local id=$1 name=$2 existing
    existing=$(forge_curl "$api/repos/$slug/releases/$id/assets" 2>/dev/null \
        | jq -r --arg n "$name" 'if type == "array" then (.[] | select(.name == $n) | .id) else empty end' \
        | head -1)
    [ -n "$existing" ] || return 0
    if [ "$is_github" -eq 1 ]; then
        forge_curl -X DELETE "$api/repos/$slug/releases/assets/$existing" >/dev/null 2>&1 || true
    else
        forge_curl -X DELETE "$api/repos/$slug/releases/$id/assets/$existing" >/dev/null 2>&1 || true
    fi
}

upload_asset() {
    local id=$1 file=$2 name
    name=$(basename "$file")
    [ -f "$file" ] || die "asset not found: $file" 1
    if dry_run; then
        printf 'DRYRUN upload-asset host=%s slug=%s release=%s asset=%s bytes=%s\n' \
            "$api" "$slug" "$id" "$name" "$(wc -c < "$file")" >&2
        printf '%s\n' "$name"
        return 0
    fi
    drop_existing_asset "$id" "$name"
    if [ "$is_github" -eq 1 ]; then
        forge_curl -H "Content-Type: application/octet-stream" -X POST \
            --data-binary @"$file" \
            "https://uploads.github.com/repos/$slug/releases/$id/assets?name=$name" >/dev/null \
            || die "asset upload failed: $name" 1
    else
        forge_curl -X POST -F "attachment=@$file" \
            "$api/repos/$slug/releases/$id/assets?name=$name" >/dev/null \
            || die "asset upload failed: $name" 1
    fi
    printf '%s\n' "$name"
}

delete_tag() {
    local tag=$1
    if [ "$is_github" -eq 1 ]; then
        forge_curl -X DELETE "$api/repos/$slug/git/refs/tags/$tag" >/dev/null 2>&1 || true
    else
        forge_curl -X DELETE "$api/repos/$slug/tags/$tag" >/dev/null 2>&1 || true
    fi
}

prune_prereleases() {
    local prefix=$1 keep_days=$2 cutoff releases id tag
    cutoff=$(date -u -d "-$keep_days days" +%Y-%m-%dT%H:%M:%SZ) \
        || die "cannot compute the retention cutoff" 1
    if [ -n "${SUBSTRATE_FORGE_RELEASES_JSON:-}" ]; then
        releases=$(cat "$SUBSTRATE_FORGE_RELEASES_JSON") \
            || die "cannot read the injected release listing" 1
    elif dry_run; then
        printf 'DRYRUN prune host=%s slug=%s prefix=%s cutoff=%s (listing skipped)\n' \
            "$api" "$slug" "$prefix" "$cutoff" >&2
        return 0
    else
        releases=$(forge_curl "$api/repos/$slug/releases?per_page=100&limit=100") \
            || die "release listing failed on $api/$slug" 1
    fi
    while IFS=$'\t' read -r id tag; do
        [ -n "$id" ] || continue
        if dry_run; then
            printf 'DRYRUN prune host=%s slug=%s release=%s tag=%s\n' "$api" "$slug" "$id" "$tag" >&2
            printf 'pruned %s\n' "$tag"
            continue
        fi
        forge_curl -X DELETE "$api/repos/$slug/releases/$id" >/dev/null \
            || die "release deletion failed: $tag" 1
        delete_tag "$tag"
        printf 'pruned %s\n' "$tag"
    done < <(printf '%s' "$releases" | jq -r --arg prefix "$prefix" --arg cutoff "$cutoff" \
        '.[] | select(.prerelease == true and (.tag_name | startswith($prefix)) and (.created_at // "9999") < $cutoff) | [(.id|tostring), .tag_name] | @tsv')
}

cmd=${1:-}
[ -n "$cmd" ] || die "usage: forge.sh <upsert-issue|open-issue|issue-json|ref-status|create-release|upload-asset|prune-prereleases> ..." 2
shift

resolve_host
token=""
dry_run || resolve_token

is_github=0
[ "$api" = "https://api.github.com" ] && is_github=1

case "$cmd" in
    upsert-issue)
        [ $# -eq 3 ] || die "usage: forge.sh upsert-issue <label> <title> <body-file>" 2
        if [ "$is_github" -eq 1 ]; then github_upsert_issue "$1" "$2" "$3"; else forgejo_upsert_issue "$1" "$2" "$3"; fi
        ;;
    open-issue)
        [ $# -eq 1 ] || die "usage: forge.sh open-issue <label>" 2
        if [ "$is_github" -eq 1 ]; then github_open_issue "$1"; else forgejo_open_issue "$1"; fi
        ;;
    issue-json)
        [ $# -eq 1 ] || die "usage: forge.sh issue-json <number>" 2
        if [ "$is_github" -eq 1 ]; then github_issue_json "$1"; else forgejo_issue_json "$1"; fi
        ;;
    ref-status)
        [ $# -eq 1 ] || die "usage: forge.sh ref-status <ref>" 2
        if [ "$is_github" -eq 1 ]; then github_ref_status "$1"; else forgejo_ref_status "$1"; fi
        ;;
    create-release)
        [ $# -eq 5 ] || die "usage: forge.sh create-release <tag> <name> <prerelease> <notes-file> <target-commitish>" 2
        create_release "$1" "$2" "$3" "$4" "$5"
        ;;
    upload-asset)
        [ $# -eq 2 ] || die "usage: forge.sh upload-asset <release-id> <file>" 2
        upload_asset "$1" "$2"
        ;;
    prune-prereleases)
        [ $# -eq 2 ] || die "usage: forge.sh prune-prereleases <tag-prefix> <keep-days>" 2
        prune_prereleases "$1" "$2"
        ;;
    *)
        die "unknown subcommand: $cmd" 2
        ;;
esac
