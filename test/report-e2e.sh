#!/usr/bin/env bash
# Firing oracle for the scheduled maintenance report: dispatch the workflow,
# wait for completion, assert the queue issue exists. Skip-local/fatal-in-CI
# when no token; needs actions:write on the caller (the gate workflow has it).
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2

if [ -z "${GH_TOKEN:-}" ] && ! gh auth token >/dev/null 2>&1; then
    if [ -n "${CI:-}" ]; then
        printf 'report-e2e: no gh token in CI — cannot verify the queue\n' >&2
        exit 1
    fi
    printf 'report-e2e: skipped locally (no gh token)\n'
    exit 0
fi

before=$(gh run list --workflow substrate-report --limit 1 --json databaseId --jq '.[0].databaseId // empty' 2>/dev/null)
gh workflow run substrate-report >/dev/null 2>&1 || {
    printf 'report-e2e: dispatch failed (needs actions:write)\n' >&2
    exit 1
}
for _ in $(seq 1 36); do
    sleep 5
    run=$(gh run list --workflow substrate-report --limit 1 --json databaseId,status,conclusion --jq '.[0]' 2>/dev/null)
    run_id=$(jq -r '.databaseId // empty' <<< "$run")
    status=$(jq -r '.status // empty' <<< "$run")
    [ -n "$run_id" ] && [ "$run_id" != "$before" ] && [ "$status" = "completed" ] && break
done
if [ -z "$run_id" ] || [ "$run_id" = "$before" ] || [ "$status" != "completed" ]; then
    printf 'report-e2e: new run never completed\n' >&2
    exit 1
fi
conclusion=$(jq -r '.conclusion // empty' <<< "$run")
[ "$conclusion" = "success" ] || { printf 'report-e2e: run failed (%s)\n' "$conclusion" >&2; exit 1; }

issue=$(gh issue list --label substrate-report --state open --limit 1 --json number,title,body --jq '.[0]')
[ "$issue" != "null" ] || { printf 'report-e2e: no maintenance queue issue after run\n' >&2; exit 1; }
if [ -n "${CI:-}" ]; then
    title=$(jq -r '.title' <<< "$issue")
    body=$(jq -r '.body' <<< "$issue")
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
fi
printf 'report-e2e: queue issue present after successful dispatch\n'
