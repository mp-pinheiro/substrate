#!/usr/bin/env bash
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"
export SUBSTRATE_NO_USER_HARNESS=1
unset SUBSTRATE_VENDOR_FROM_WORKTREE
mkdir -p "$HOME"

fail() { printf 'vendor-source-test FAIL: %s\n' "$1" >&2; exit 1; }

mkdir -p "$T/kit"
cp -R "$KIT_ROOT"/bin "$KIT_ROOT"/core "$KIT_ROOT"/profiles "$KIT_ROOT"/skills \
      "$KIT_ROOT"/agents "$KIT_ROOT"/VERSION "$KIT_ROOT"/substrate.json "$T/kit/"
[ ! -f "$KIT_ROOT/engine.json" ] || cp "$KIT_ROOT/engine.json" "$T/kit/"
cp -R "$KIT_ROOT/.substrate" "$T/kit/.substrate"
cp "$KIT_ROOT/substrate-baseline.json" "$T/kit/substrate-baseline.json"
# The fake kit's own substrate.json is scoped to a kit-shipped profile only —
# self-hosting's repo-local substrate-profiles/kit-ts is orthogonal to the guard under test.
jq '.profiles = ["base"]' "$KIT_ROOT/substrate.json" > "$T/kit/substrate.json"
git init -q --initial-branch=main "$T/kit"
git -C "$T/kit" config user.name substrate
git -C "$T/kit" config user.email substrate@localhost
git -C "$T/kit" add -A
git -C "$T/kit" commit -qm 'chore: seed fake kit'
git init -q --bare "$T/origin"
git -C "$T/kit" remote add origin "$T/origin"
git -C "$T/kit" push -q -u origin main

new_consumer() {
    rm -rf "$T/consumer" && mkdir -p "$T/consumer" && cd "$T/consumer" || return 1
    git init -q --initial-branch=main
    git config user.name substrate
    git config user.email substrate@localhost
    printf 'safe\n' > tracked.txt
    git add -A && git commit -qm 'chore: seed consumer'
}

reset_kit() {
    git -C "$T/kit" reset --hard -q origin/main
    git -C "$T/kit" clean -qfd
}

# Clean kit: init succeeds and records provenance
reset_kit
new_consumer || fail "consumer setup failed (case 1)"
"$T/kit/bin/substrate" init --profile base --vcs git >/dev/null 2>&1 \
    || fail "init from a clean kit refused"
kit_rev=$(git -C "$T/kit" rev-parse HEAD)
jq -e --arg r "$kit_rev" '.kitRevision == $r and .source == "trunk"' .substrate/vendor.json >/dev/null \
    || fail "vendor.json did not record the trunk revision"

# Dirty kit source (core/): refuses
reset_kit
new_consumer || fail "consumer setup failed (case 2)"
printf '\n' >> "$T/kit/core/gate-lib.sh"
if "$T/kit/bin/substrate" init --profile base --vcs git > "$T/case2.out" 2>&1; then
    fail "init from a dirty kit checkout was not refused"
fi
grep -q 'uncommitted vendor sources' "$T/case2.out" || fail "dirty-kit refusal was not actionable"

# Dirty kit source (skills/): refuses, proves the widened pathspec
reset_kit
new_consumer || fail "consumer setup failed (case 3)"
printf 'x\n' >> "$T/kit/skills/review/SKILL.md"
if "$T/kit/bin/substrate" init --profile base --vcs git > "$T/case3.out" 2>&1; then
    fail "init with dirty skills/ was not refused"
fi
grep -q 'uncommitted vendor sources' "$T/case3.out" || fail "dirty skills/ refusal was not actionable"

# Unpushed kit commit: refuses; --from-worktree opts in
reset_kit
new_consumer || fail "consumer setup failed (case 4)"
printf '\n' >> "$T/kit/core/gate-lib.sh"
git -C "$T/kit" commit -qam 'chore: unpushed kit change'
if "$T/kit/bin/substrate" init --profile base --vcs git > "$T/case4.out" 2>&1; then
    fail "init from an unpushed kit revision was not refused"
fi
grep -q 'is not contained in origin/main' "$T/case4.out" || fail "unpushed-revision refusal was not actionable"
"$T/kit/bin/substrate" init --profile base --vcs git --from-worktree >/dev/null 2>&1 \
    || fail "--from-worktree did not opt into an unpushed kit revision"
jq -e '.source == "worktree" and .kitRevision == "worktree"' .substrate/vendor.json >/dev/null \
    || fail "--from-worktree vendoring did not record worktree provenance"

# jj leg
reset_kit
(cd "$T/kit" && jj git init --colocate .) >/dev/null 2>&1 || fail "jj colocate failed"
new_consumer || fail "consumer setup failed (case 5a)"
"$T/kit/bin/substrate" init --profile base --vcs git >/dev/null 2>&1 \
    || fail "jj-leg init from a clean kit refused"
jq -e '.source == "trunk"' .substrate/vendor.json >/dev/null || fail "jj-leg clean init did not record trunk"

new_consumer || fail "consumer setup failed (case 5b)"
printf '\n' >> "$T/kit/core/gate-lib.sh"
(cd "$T/kit" && jj commit -m 'chore: unpushed jj change') >/dev/null 2>&1 \
    || fail "jj commit failed"
if "$T/kit/bin/substrate" init --profile base --vcs git > "$T/case5b.out" 2>&1; then
    fail "jj-leg init from an unpushed revision was not refused"
fi
grep -q 'is not contained in main@origin' "$T/case5b.out" || fail "jj-leg unpushed refusal was not actionable"

# Kit-self exemption: the kit vendoring into itself must not refuse even when dirty
(cd "$T/kit" && ./bin/substrate update) >/dev/null 2>&1 \
    || fail "kit-self vendoring was refused despite the exemption"
rm -rf "$T/kit/.jj"


printf 'vendor-source-test: fitness guard, provenance, worktree opt-in, jj leg, kit-self exemption green\n'
