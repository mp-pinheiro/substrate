#!/usr/bin/env bash
# Tracked JSON must parse (jq, hard requirement). Tracked YAML parses when yq
# is available; its absence is a loud skip everywhere — the CI template does
# not ship yq, so this stays advisory until a repo opts in.
set -uo pipefail
# shellcheck source=../gate-lib.sh
source "$SUBSTRATE_DIR/gate-lib.sh"

rc=0
while IFS= read -r f; do
    unscanned_match "$f" && continue
    case "$f" in
        *.json)
            if ! jq -e . "$f" >/dev/null 2>&1; then
                printf 'invalid JSON: %s\n' "$f"
                rc=1
            fi
            ;;
    esac
done < "$INVENTORY"

if have yq; then
    while IFS= read -r f; do
        unscanned_match "$f" && continue
        case "$f" in
            *.yml|*.yaml)
                if ! yq eval '.' "$f" >/dev/null 2>&1; then
                    printf 'invalid YAML: %s\n' "$f"
                    rc=1
                fi
                ;;
        esac
    done < "$INVENTORY"
else
    warn "yq not installed — YAML validity not checked"
fi

exit "$rc"
