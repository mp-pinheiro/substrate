#!/usr/bin/env bash
set -uo pipefail
source "$SUBSTRATE_DIR/gate-lib.sh"

go_dir=$(go_workspace_dir "76-golangci.sh")
workspace_rc=$?
if [ "$workspace_rc" -eq 1 ]; then
    warn "no go.mod — golangci-lint inactive"
    exit 0
fi
[ "$workspace_rc" -eq 0 ] || exit "$workspace_rc"
if [ ! -f "$REPO_ROOT/.golangci.yml" ]; then
    warn "no .golangci.yml — golangci-lint inactive (substrate init installs a template)"
    exit 0
fi
require_bin_ci golangci-lint "profile toolchain — see profiles/go/profile.json" || exit 0

out=$(cd "$go_dir" && golangci-lint run --timeout 3m --config "$REPO_ROOT/.golangci.yml" 2>&1)
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
