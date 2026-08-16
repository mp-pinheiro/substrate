#!/usr/bin/env bash
# Firing oracle for the scheduled maintenance report: dispatch the workflow,
# wait for the queue issue to update, assert its contents. Skip-local/fatal-in-CI
# when no token; needs actions:write on the caller (the gate workflow has it).
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2

n=$(.substrate/forge.sh open-issue substrate-report)
rc=$?
if [ "$rc" -eq 3 ]; then
    # CI alone does not prove a forge runner — agent harnesses also export
    # CI=true; only a runner injects GITHUB_REPOSITORY, needed to dispatch.
    if [ -n "${CI:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
        printf 'report-e2e: no usable token on the forge runner — cannot verify the queue\n' >&2
        exit 1
    fi
    printf 'report-e2e: unverifiable — no forge token and no runner repository\n' >&2
    exit 3
elif [ "$rc" -ne 0 ]; then
    printf 'report-e2e: open-issue lookup failed\n' >&2
    exit 1
fi
before=""
[ -n "$n" ] && before=$(.substrate/forge.sh issue-json "$n" | jq -r '.updated_at')

api=${GITHUB_API_URL:-https://api.github.com}
if [ "$api" = "https://api.github.com" ]; then
    gh workflow run substrate-report >/dev/null 2>&1 || {
        printf 'report-e2e: dispatch failed (needs actions:write)\n' >&2
        exit 1
    }
else
    token=${GITHUB_TOKEN:-${GH_TOKEN:-}}
    curl -sSf -X POST -H "Authorization: token $token" -H "Content-Type: application/json" \
        "$api/repos/$GITHUB_REPOSITORY/actions/workflows/substrate-report.yml/dispatches" \
        -d '{"ref":"main"}' >/dev/null || {
        printf 'report-e2e: dispatch failed (needs actions:write)\n' >&2
        exit 1
    }
fi

issue_json=""
for _ in $(seq 1 36); do
    sleep 5
    m=$(.substrate/forge.sh open-issue substrate-report) || continue
    [ -n "$m" ] || continue
    candidate=$(.substrate/forge.sh issue-json "$m") || continue
    updated=$(jq -r '.updated_at' <<< "$candidate")
    if [ -z "$before" ] || [ "$updated" != "$before" ]; then
        issue_json=$candidate
        break
    fi
done
if [ -z "$issue_json" ]; then
    printf 'report-e2e: queue issue never updated after dispatch\n' >&2
    exit 1
fi

title=$(jq -r '.title' <<< "$issue_json")
body=$(jq -r '.body' <<< "$issue_json")
if [ -n "${CI:-}" ]; then
    first_line=${body%%$'\n'*}
    [ "$first_line" = "# Substrate maintenance report" ] \
        || { printf 'report-e2e: issue body is not rendered Markdown\n' >&2; exit 1; }
    [ "$title" = "Substrate maintenance report: cleanup candidates" ] \
        || { printf 'report-e2e: issue title stale (%s)\n' "$title" >&2; exit 1; }
    grep -q '^# Substrate maintenance report$' <<< "$body" \
        || { printf 'report-e2e: issue body heading missing\n' >&2; exit 1; }
    grep -q '^## Duplicate code$' <<< "$body" \
        || { printf 'report-e2e: issue body sections missing\n' >&2; exit 1; }
    if grep -q 'Status: not scanned' <<< "$body"; then
        printf 'report-e2e: issue contains an unscanned section\n' >&2
        exit 1
    fi
    if grep -Eq 'creating virtual environment|installing vulture' <<< "$body"; then
        printf 'report-e2e: issue contains pipx setup noise\n' >&2
        exit 1
    fi
fi
printf 'report-e2e: queue issue present after successful dispatch\n'
