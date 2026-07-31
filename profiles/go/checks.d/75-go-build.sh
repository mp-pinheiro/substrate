#!/usr/bin/env bash
# Compiles and vets the Go module: `go build ./...` then `go vet ./...`.
# Compiler and vet output are the findings; without go.mod the check is inactive.
set -uo pipefail
# shellcheck source=../gate-lib.sh
source "$SUBSTRATE_DIR/gate-lib.sh"

if [ ! -f "$REPO_ROOT/go.mod" ]; then
    warn "no go.mod — go build/vet inactive"
    exit 0
fi
require_bin_ci go "profile toolchain — see profiles/go/profile.json" || exit 0

if ! out=$(go build ./... 2>&1); then
    printf '%s\n' "$out"
    exit 1
fi
if ! out=$(go vet ./... 2>&1); then
    printf '%s\n' "$out"
    exit 1
fi
exit 0
