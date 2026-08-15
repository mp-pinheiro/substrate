#!/usr/bin/env bash
# Host-detecting issue/status client for the maintenance report queue and the
# plan audit oracles. Picks GitHub (gh CLI) or a Forgejo-shaped host (curl
# against the Gitea-compatible /api/v1) purely from the resolved API host —
# no repo config, no env flag.
#   upsert-issue <label> <title> <body-file>   ensure label + issue; print number
#   open-issue <label>                         print newest open issue number, or nothing
#   issue-json <number>                        print that issue's API JSON object
#   ref-status <ref>                           print success|failure|pending, or nothing
set -uo pipefail

die() { printf 'forge: %s\n' "$1" >&2; exit "${2:-1}"; }

resolve_host() {
    api=${GITHUB_API_URL:-}
    slug=${GITHUB_REPOSITORY:-}
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
    token=${GITHUB_TOKEN:-${GH_TOKEN:-}}
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
    forgejo_curl "$api/repos/$slug/commits/$1/statuses?limit=1" | jq -r '.[0].status // empty' \
        || die "forgejo status lookup failed" 1
}

cmd=${1:-}
[ -n "$cmd" ] || die "usage: forge.sh <upsert-issue|open-issue|issue-json|ref-status> ..." 2
shift

resolve_host
resolve_token

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
    *)
        die "unknown subcommand: $cmd" 2
        ;;
esac
