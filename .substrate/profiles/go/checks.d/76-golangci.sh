#!/usr/bin/env bash
# Runs golangci-lint with the repo's .golangci.yml (installed as a template).
# Exit 1 from the linter = findings; any other nonzero = infra failure.
set -uo pipefail
# shellcheck source=../gate-lib.sh
source "$SUBSTRATE_DIR/gate-lib.sh"

if [ ! -f "$REPO_ROOT/.golangci.yml" ]; then
    warn "no .golangci.yml — golangci-lint inactive (substrate init installs a template)"
    exit 0
fi
if [ ! -f "$REPO_ROOT/go.mod" ]; then
    warn "no go.mod — golangci-lint inactive"
    exit 0
fi
require_bin_ci golangci-lint "profile toolchain — see profiles/go/profile.json" || exit 0

out=$(golangci-lint run --timeout 3m --config "$REPO_ROOT/.golangci.yml" 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then
    exit 0
fi
if [ "$rc" -eq 1 ]; then
    printf '%s\n' "$out"
    exit 1
fi
printf '%s\n' "$out"
die_infra "golangci-lint failed with rc=$rc (config or internal error, not findings)"
