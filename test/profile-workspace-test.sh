#!/usr/bin/env bash
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'profile-workspace-test FAIL: %s\n' "$1" >&2; exit 1; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
repo="$T/repo"
mkdir -p "$repo/backend" "$T/bin"
mkdir -p "$repo/backend/cmd/probe"
printf 'package main\nfunc main() {}\n' > "$repo/backend/cmd/probe/main.go"
printf 'module example.com/backend\n\ngo 1.22\n' > "$repo/backend/go.mod"
printf 'package backend\n\nfunc Probe() {}\n' > "$repo/backend/probe.go"
printf 'run:\n  timeout: 3m\n' > "$repo/.golangci.yml"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s %s\n" "$PWD" "$*" > "$GOLANGCI_LOG"' > "$T/bin/golangci-lint"
chmod +x "$T/bin/golangci-lint"
printf 'backend/go.mod\nbackend/probe.go\n' > "$T/inventory"
printf '{"checks":{"config":{"75-go-build.sh":{"directory":"backend"},"76-golangci.sh":{"directory":"backend"}}}}\n' > "$repo/substrate.json"
printf '{}\n' > "$T/langmap.json"
printf '{}\n' > "$T/metrics.jsonl"
printf '{}\n' > "$T/baseline.json"

run_check() {
    local name="$1"
    REPO_ROOT="$repo" SUBSTRATE_DIR="$KIT_ROOT/core" CONFIG="$repo/substrate.json" \
        LANGMAP="$T/langmap.json" INVENTORY="$T/inventory" METRICS="$T/metrics.jsonl" \
        BASELINE="$T/baseline.json" GOLANGCI_LOG="$T/golangci.log" \
        SUBSTRATE_CHECK_NAME="$name" PATH="$T/bin:$PATH" \
        bash "$KIT_ROOT/profiles/go/checks.d/$name"
}

run_check 75-go-build.sh || fail "nested go build/vet failed"
run_check 76-golangci.sh || fail "nested golangci-lint failed"
grep -q "^$repo/backend run" "$T/golangci.log" \
    || fail "golangci-lint did not run from the configured module"
grep -q -- "--config $repo/.golangci.yml" "$T/golangci.log" \
    || fail "golangci-lint did not resolve config from repository root"

for bad in '/backend' '../backend' 'missing' 'empty'; do
    if [ "$bad" = empty ]; then
        mkdir -p "$repo/empty"
    fi
    jq --arg d "$bad" '.checks.config["75-go-build.sh"].directory = $d | .checks.config["76-golangci.sh"].directory = $d' \
        "$repo/substrate.json" > "$repo/substrate.json.tmp" && mv "$repo/substrate.json.tmp" "$repo/substrate.json"
    for name in 75-go-build.sh 76-golangci.sh; do
        if run_check "$name" > "$T/failure.out" 2>&1; then
            fail "$name accepted invalid directory $bad"
        fi
        grep -q "$name" "$T/failure.out" || fail "$name did not name invalid directory $bad"
    done
done

printf 'profile-workspace-test: nested module execution and path validation green\n'
