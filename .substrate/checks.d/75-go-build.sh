#!/usr/bin/env bash
set -uo pipefail
source "$SUBSTRATE_DIR/gate-lib.sh"

go_dir=$(go_workspace_dir "75-go-build.sh")
workspace_rc=$?
if [ "$workspace_rc" -eq 1 ]; then
    warn "no go.mod — go build/vet inactive"
    exit 0
fi
[ "$workspace_rc" -eq 0 ] || exit "$workspace_rc"
require_bin go "profile toolchain — see profiles/go/profile.json"

build_output=$(mktemp -d) || die_infra "could not create isolated go build output"
trap 'rm -rf "$build_output"' EXIT

if ! out=$(cd "$go_dir" && go build -o "$build_output/" ./... 2>&1); then
    printf '%s\n' "$out"
    exit 1
fi
if ! out=$(cd "$go_dir" && go vet ./... 2>&1); then
    printf '%s\n' "$out"
    exit 1
fi
exit 0
