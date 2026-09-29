#!/usr/bin/env bash
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"
export SUBSTRATE_NO_USER_HARNESS=1
mkdir -p "$HOME"

fail() { printf 'gitleaks-scope-test FAIL: %s\n' "$1" >&2; exit 1; }
scan_red() {
    local label="$1" expected="$2" out
    if out=$(.substrate/checks.d/50-gitleaks.sh 2>&1); then
        fail "$label was not detected"
    fi
    printf '%s\n' "$out" | grep -Fq "$expected" || fail "$label report did not name $expected"
}
scan_green() {
    local label="$1" out
    if ! out=$(.substrate/checks.d/50-gitleaks.sh 2>&1); then
        fail "$label: $out"
    fi
}

command -v gitleaks >/dev/null 2>&1 || fail "gitleaks is not installed"
canary='ghp_'
canary+='A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8'

mkdir -p "$T/git-repo"
cd "$T/git-repo" || exit 9
export SUBSTRATE_DIR="$PWD/.substrate"
git init -q --initial-branch=main
git config user.name substrate
git config user.email substrate@localhost
printf 'safe\n' > tracked.txt
"$KIT_ROOT/bin/substrate" init --profile base --vcs git >/dev/null 2>&1 || fail "Git init failed"
git add -A
git commit -qm 'chore: initialize'
scan_green "clean Git tree failed"

printf '%s\n' "$canary" > tracked.txt
scan_red "Git tracked modification" tracked.txt
git restore -- tracked.txt

printf '%s\n' "$canary" > staged.txt
git add staged.txt
scan_red "Git staged addition" staged.txt
git reset -q -- staged.txt
rm -f staged.txt

printf '%s\n' "$canary" > untracked.txt
scan_red "Git untracked addition" untracked.txt
rm -f untracked.txt
scan_green "clean Git tree did not recover"

mkdir -p "$T/jj-repo"
cd "$T/jj-repo" || exit 9
export SUBSTRATE_DIR="$PWD/.substrate"
jj config set --user user.name substrate >/dev/null 2>&1
jj config set --user user.email substrate@localhost >/dev/null 2>&1
git init -q --initial-branch=main
jj git init --colocate . >/dev/null 2>&1 || fail "Jujutsu init failed"
printf 'safe\n' > tracked.txt
"$KIT_ROOT/bin/substrate" init --profile base --vcs jj >/dev/null 2>&1 || fail "Jujutsu substrate init failed"
jj commit -m 'chore: initialize' >/dev/null 2>&1 || fail "Jujutsu seed commit failed"
scan_green "clean Jujutsu tree failed"

printf '%s\n' "$canary" > tracked.txt
scan_red "Jujutsu tracked modification" tracked.txt
jj restore tracked.txt >/dev/null 2>&1

printf '%s\n' "$canary" > untracked.txt
scan_red "Jujutsu untracked addition" untracked.txt
jj restore untracked.txt >/dev/null 2>&1
scan_green "clean Jujutsu tree did not recover"

mkdir -p "$T/maintenance-git" "$T/maintenance-origin.git"
git init -q --bare "$T/maintenance-origin.git"
git -C "$T/maintenance-git" init -q --initial-branch=main
cd "$T/maintenance-git" || exit 9
git config user.name substrate
git config user.email substrate@localhost
"$KIT_ROOT/bin/substrate" init --profile base --vcs git >/dev/null 2>&1 \
    || fail "maintenance fixture initialization failed"
printf '%s\n' "$canary" > legacy.txt
git add -A
git commit -qm 'chore: seed legacy canary'
git remote add origin "$T/maintenance-origin.git"
git push -q --no-verify -u origin main || fail "maintenance fixture push failed"
git fetch -q origin || fail "maintenance fixture fetch failed"
git show-ref --verify --quiet refs/remotes/origin/main \
    || fail "maintenance fixture origin ref missing"
if ! out=$("$KIT_ROOT/bin/substrate" bootstrap --profile base --vcs git --checkpoint --accept-baseline --repo-only 2>&1); then
    fail "maintenance candidate rejected the unchanged seed: $out"
fi
if printf '%s\n' "$out" | grep -Fq 'legacy.txt'; then
    fail "maintenance candidate reported unchanged legacy.txt"
fi
dirty_canary='ghp_'
dirty_canary+='Z9y8X7w6V5u4T3s2R1q0P9o8N7m6L5k4J3i2'
jq --arg canary "$dirty_canary" '.maintenanceProbe = $canary' substrate.json > "$T/substrate.json" \
    || fail "dirty substrate.json rewrite failed"
mv "$T/substrate.json" substrate.json
if out=$("$KIT_ROOT/bin/substrate" bootstrap --repo-only 2>&1); then
    fail "maintenance candidate missed dirty substrate.json secret"
fi
printf '%s\n' "$out" | grep -Fq 'substrate.json' \
    || fail "dirty substrate.json finding was not reported"
printf '%s\n' "$out" | grep -Fq 'potential secrets in pending work' \
    || fail "pending secret failure was not reported"

printf 'gitleaks-scope-test: Git tracked, staged, untracked and Jujutsu pending coverage green\n'
