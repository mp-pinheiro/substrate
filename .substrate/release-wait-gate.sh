#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
forge="${RELEASE_FORGE_BIN:-$here/forge.sh}"
sha="${RELEASE_HEAD_SHA:?RELEASE_HEAD_SHA is required}"
event="${RELEASE_EVENT:-workflow_dispatch}"
attempts="${RELEASE_GATE_ATTEMPTS:-60}"
delay="${RELEASE_GATE_DELAY:-10}"
out_file="${RELEASE_OUTPUT:-${GITHUB_OUTPUT:-/dev/stdout}}"
status=""

for ((attempt=1; attempt<=attempts; attempt++)); do
    status=$($forge ref-status "$sha")
    case "$status" in
        success)
            printf 'status=success\n' >> "$out_file"
            exit 0
            ;;
        failure)
            if [ "$event" = schedule ]; then
                printf 'status=failure\n' >> "$out_file"
                printf '::notice::gate failed for %s — nothing to publish tonight\n' "$sha"
                exit 0
            fi
            printf '::error::gate failed for %s — refusing release\n' "$sha" >&2
            exit 1
            ;;
    esac
    if [ "$attempt" -lt "$attempts" ]; then
        sleep "$delay"
    fi
done

printf 'status=%s\n' "$status" >> "$out_file"
if [ "$event" = schedule ]; then
    printf "::notice::gate status for %s is '%s' — nothing to publish tonight\n" "$sha" "${status:-unknown}"
    exit 0
fi
printf "::error::gate status for %s stayed '%s' — refusing release\n" "$sha" "${status:-unknown}" >&2
exit 1
