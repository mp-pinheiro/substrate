#!/usr/bin/env bash
# LSP feedback tier: init must seed .omp/lsp.json from the active profiles'
# lsp keys (absent-only — repo edits win forever), and doctor must report
# missing servers as informational hints, never warnings.
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# scratch inits must never touch the live user harness (~/.claude, ~/.omp)
export SUBSTRATE_NO_USER_HARNESS=1

fail() { printf 'lsp-config-test FAIL: %s\n' "$1" >&2; exit 1; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
cd "$T" || exit 9
git init -q .
git config user.email substrate@localhost
git config user.name substrate
env -u CI "$KIT_ROOT/bin/substrate" init --profile shell,lua >/dev/null 2>&1 || fail "init failed"

[ -f .omp/lsp.json ] || fail ".omp/lsp.json not seeded"
jq -e '.servers.bashls.disabled == false' .omp/lsp.json >/dev/null || fail "bashls missing: $(cat .omp/lsp.json)"
jq -e '[.servers.bashls.fileTypes[]] | (any(. == ".zshenv") and any(. == ".sh"))' .omp/lsp.json >/dev/null \
    || fail "bashls fileTypes must route .zshenv (basename route) and keep .sh: $(jq -c '.servers.bashls.fileTypes' .omp/lsp.json)"
jq -e '.servers."lua-language-server".disabled == false' .omp/lsp.json >/dev/null || fail "lua-language-server missing"
jq -e '.idleTimeoutMs == 300000' .omp/lsp.json >/dev/null || fail "idleTimeoutMs missing"
jq -e '.servers | keys | length >= 4' .omp/lsp.json >/dev/null || fail "base profile lsp keys missing"

out=$("$KIT_ROOT/bin/substrate" doctor 2>&1)
grep -q 'lsp bashls: bash-language-server' <<< "$out" || fail "doctor says nothing about bashls: $out"
grep -q 'lsp lua-language-server:' <<< "$out" || fail "doctor says nothing about lua server"
grep -E '^\[!\] lsp ' <<< "$out" && fail "doctor warns about absent LSP servers (must be informational)"

printf '{"servers": {"bashls": {"disabled": true}}}\n' > .omp/lsp.json
env -u CI "$KIT_ROOT/bin/substrate" init --profile shell,lua >/dev/null 2>&1
jq -e '.servers.bashls.disabled == true' .omp/lsp.json >/dev/null || fail "re-init clobbered repo-owned .omp/lsp.json"

printf 'lsp-config-test: seed, doctor hints, absent-only green\n'
