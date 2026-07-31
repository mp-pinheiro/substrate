#!/usr/bin/env bash
# Lints GitHub workflow files with actionlint. yq tolerates duplicate keys, so
# data-validity alone passes structurally broken workflows — this catches them.
set -uo pipefail
# shellcheck source=../../../core/gate-lib.sh
source "$SUBSTRATE_DIR/gate-lib.sh"

files=()
while IFS= read -r f; do
    case "$f" in
        .github/workflows/*.yml|.github/workflows/*.yaml)
            unscanned_match "$f" && continue
            files+=("$f")
            ;;
    esac
done < "$INVENTORY"
[ ${#files[@]} -eq 0 ] && exit 0

require_bin_ci actionlint "https://github.com/rhysd/actionlint (single static binary)" || exit 0

out=$(actionlint -no-color "${files[@]}")
rc=$?
if [ "$rc" -eq 0 ]; then
    exit 0
fi
if [ -n "$out" ]; then
    printf '%s\n' "$out"
    exit 1
fi
die_infra "actionlint failed (rc=$rc) with no findings output"
