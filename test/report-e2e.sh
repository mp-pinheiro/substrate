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

gh workflow run substrate-report >/dev/null 2>&1 || {
    printf 'report-e2e: dispatch failed (needs actions:write)\n' >&2
    exit 1
}
for _ in $(seq 1 36); do
    sleep 5
    status=$(gh run list --workflow substrate-report --limit 1 --json status --jq '.[0].status' 2>/dev/null)
    [ "$status" = "completed" ] && break
done
[ "$status" = "completed" ] || { printf 'report-e2e: run never completed\n' >&2; exit 1; }

count=$(gh issue list --label substrate-report --state open --json number --jq 'length')
[ "${count:-0}" -ge 1 ] || { printf 'report-e2e: no maintenance queue issue after run\n' >&2; exit 1; }
printf 'report-e2e: queue issue present after dispatched run\n'
