#!/usr/bin/env bash
# Negative battery for the contracts pillar: drifted generated output must go
# red with the check named; regen never mutates the working tree; a missing
# generator is infra-red under CI; the write hook blocks generated paths
# (directory containment included) and fails closed on malformed entries.
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# scratch inits must never touch the live user harness (~/.claude, ~/.omp)
export SUBSTRATE_NO_USER_HARNESS=1

fail() { printf 'contract-drift-test FAIL: %s\n' "$1" >&2; exit 1; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
cd "$T" || exit 9
git init -q .
git config user.email substrate@localhost
git config user.name substrate

env -u CI "$KIT_ROOT/bin/substrate" init --profile shell >/dev/null 2>&1 || fail "init failed"
printf '#!/usr/bin/env bash\nmkdir -p gen/sub\nprintf "v2\\n" > gen/out.txt\nprintf "n2\\n" > gen/sub/nested.txt\n' > gen.sh
chmod +x gen.sh
mkdir -p gen/sub
printf 'v1\n' > gen/out.txt
printf 'n1\n' > gen/sub/nested.txt
jq '.contracts = [{"name": "demo", "regen": "./gen.sh", "paths": ["gen"]}] | .unscanned += ["gen/**", "gen.sh", "*.md"]' \
    substrate.json > s.tmp && mv s.tmp substrate.json
git add -A
git commit -qm seed

out=$(env -u CI substrate-engine gate 2>&1)
printf '%s' "$out" | grep -q "45-contract-drift" || fail "gate output never names the drift check"
printf '%s' "$out" | grep -q "drifted from its source" || fail "stale gen/ not reported as drift"
[ "$(cat gen/out.txt)" = "v1" ] || fail "gate mutated the working tree during regen"

./gen.sh
git add -A
git commit -qm regen
env -u CI substrate-engine gate --update-baseline >/dev/null 2>&1 || fail "in-sync directory contract not green"

jq '.contracts[0].regen = "substrate-no-such-generator-xyz"' substrate.json > s.tmp && mv s.tmp substrate.json
git add -A && git commit -qm break-gen
out=$(env CI=1 substrate-engine gate 2>&1)
rc=$?
[ "$rc" -ne 0 ] || fail "missing generator passed under CI"
printf '%s' "$out" | grep -qi "not installed\|missing in CI\|cannot pass blind" || fail "missing generator not reported as infra: $out"
jq '.contracts[0].regen = "./gen.sh"' substrate.json > s.tmp && mv s.tmp substrate.json

hook_out=$(printf '{"tool_input": {"file_path": "gen/sub/nested.txt"}}' | substrate-engine hook protect-paths 2>&1)
hook_rc=$?
[ "$hook_rc" -eq 2 ] || fail "hook did not block a nested generated path (rc=$hook_rc)"
printf '%s' "$hook_out" | grep -q "generated from a contract" || fail "hook block message wrong: $hook_out"

jq '.contracts = [{"name": "bad", "regen": "./gen.sh", "paths": "gen"}]' substrate.json > s.tmp && mv s.tmp substrate.json
hook_out=$(printf '{"tool_input": {"file_path": "anything.txt"}}' | substrate-engine hook protect-paths 2>&1)
hook_rc=$?
[ "$hook_rc" -eq 2 ] || fail "hook did not fail closed on malformed contracts (rc=$hook_rc)"
printf '%s' "$hook_out" | grep -q "contracts entries need" || fail "malformed-contracts block message wrong (syntax-error rc=2 also lands here): $hook_out"

printf 'contract-drift-test: 5 cases green\n'
