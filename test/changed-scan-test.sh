#!/usr/bin/env bash
# Firing battery for changed-files-scan.sh: bash-side writes (the hole the
# write/edit-only ratchet left open) must be caught from the tree diff alone,
# in both VCS modes; protected paths written around the write hook must be
# named; a clean tree must stay silent; violations must never be memoized;
# and an edit that restores mtime at the same size must still be rescanned.
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# scratch inits must never touch the live user harness (~/.claude, ~/.omp)
export SUBSTRATE_NO_USER_HARNESS=1

fail() { printf 'changed-scan-test FAIL: %s\n' "$1" >&2; exit 1; }

run_scan() {
    substrate-engine hook changed-files-scan </dev/null 2>"$1"
}

seed_repo() {
    mkdir -p components
    printf '#!/usr/bin/env bash\nset -euo pipefail\nls "$@"\n' > components/x.sh
    chmod +x components/x.sh
    env -u CI "$KIT_ROOT/bin/substrate" init --profile shell >/dev/null 2>&1 || fail "$1: init failed"
}

battery() {
    local vcs="$1" err rc
    err=$(mktemp)

    run_scan "$err"
    rc=$?
    [ "$rc" -eq 0 ] || fail "$vcs: clean tree exited $rc: $(cat "$err")"
    [ -s "$err" ] && fail "$vcs: clean tree produced output: $(cat "$err")"

    printf '# now we check the thing\n# first we validate, then we proceed\n# finally we finish\n' >> components/x.sh
    run_scan "$err"
    rc=$?
    [ "$rc" -eq 2 ] || fail "$vcs: bash-appended slop exited $rc, want 2"
    grep -q 'components/x.sh' "$err" || fail "$vcs: report does not name components/x.sh: $(cat "$err")"

    run_scan "$err"
    rc=$?
    [ "$rc" -eq 2 ] || fail "$vcs: violation vanished on re-run (memoized failure?)"

    printf '# now we narrate the new file\n# then we narrate some more\nls\n' > components/fresh.sh
    run_scan "$err"
    grep -q 'components/fresh.sh' "$err" || fail "$vcs: untracked new file not scanned: $(cat "$err")"

    local tmp
    tmp=$(mktemp)
    jq '.protected_paths = ["substrate-baseline.json"]' substrate.json > "$tmp" && mv "$tmp" substrate.json
    printf 'x' >> substrate-baseline.json
    run_scan "$err"
    rc=$?
    [ "$rc" -eq 2 ] || fail "$vcs: protected tamper exited $rc, want 2"
    grep -q 'protected path written outside the write hook: substrate-baseline.json' "$err" \
        || fail "$vcs: protected tamper not named: $(cat "$err")"
    rm -f "$err"
}

# one memo line per distinct key: a rescan appends, a memo hit does not
memo_keys() {
    local f n total=0
    for f in "${TMPDIR:-/tmp}"/substrate-scan-*; do
        [ -f "$f" ] || continue
        n=$(grep -cF "$1|" "$f") || n=0
        total=$((total + n))
    done
    printf '%s' "$total"
}

write_memo() {
    printf '#!/usr/bin/env bash\nset -euo pipefail\nls "$@"\n# %s\n' "$1" > components/memo.sh
}

# rewrite at an identical byte count and restore the mtime from $2, so the file
# carries the exact mtime:size signature ($3) it had before the edit
respin() {
    write_memo "$1"
    touch -r "$2" components/memo.sh
    [ "$(stat -c '%.9Y:%s' components/memo.sh)" = "$3" ] \
        || fail "memo: payload width or mtime not restored — the stale-key case would go untested"
}

# The memo may not key on mtime:size: an editor that rewrites a file at the same
# length and restores its mtime leaves that signature untouched.
memo_battery() {
    local err stamp base rc
    err=$(mktemp)
    stamp=$(mktemp)

    write_memo 'rhubarb rhubarb rhub'
    run_scan "$err"
    rc=$?
    [ "$rc" -eq 0 ] || fail "memo: clean new file exited $rc: $(cat "$err")"
    [ "$(memo_keys components/memo.sh)" = 1 ] || fail "memo: passing scan was not memoized"
    base=$(stat -c '%.9Y:%s' components/memo.sh)
    touch -r components/memo.sh "$stamp"

    respin 'now we check the box' "$stamp" "$base"
    run_scan "$err"
    rc=$?
    [ "$rc" -eq 2 ] || fail "memo: same-signature slop edit exited $rc, want 2 — stale memo hit"
    grep -q 'components/memo.sh' "$err" || fail "memo: rescan did not name the file: $(cat "$err")"
    [ "$(memo_keys components/memo.sh)" = 1 ] || fail "memo: a failing scan was memoized"

    respin 'custard custard cust' "$stamp" "$base"
    run_scan "$err"
    rc=$?
    [ "$rc" -eq 0 ] || fail "memo: repaired file exited $rc: $(cat "$err")"
    [ "$(memo_keys components/memo.sh)" = 2 ] || fail "memo: re-ratcheted pass added no key"

    run_scan "$err"
    rc=$?
    [ "$rc" -eq 0 ] || fail "memo: untouched file exited $rc: $(cat "$err")"
    [ "$(memo_keys components/memo.sh)" = 2 ] || fail "memo: unchanged content missed the memo"
    rm -f "$err" "$stamp" components/memo.sh
}

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/git-repo"
(
    cd "$T/git-repo" || exit 9
    git init -q .
    git config user.email substrate@localhost
    git config user.name substrate
    seed_repo git
    git add -A
    git commit -qm 'feat: seed'
    out=$(env -u CI substrate-engine gate --update-baseline 2>&1) || fail "git: baseline not green: $out"
    git add -A
    git commit -qm 'chore: baseline'
    # private TMPDIR: memo_keys reads the cache dir, and /tmp keeps every earlier run's cache
    (
        mkdir -p "$T/memo-tmp" || fail "memo: private TMPDIR not created"
        export TMPDIR="$T/memo-tmp"
        memo_battery
    ) || exit 1
    battery git
) || exit 1

mkdir -p "$T/jj-repo"
(
    cd "$T/jj-repo" || exit 9
    jj git init >/dev/null 2>&1 || { printf 'changed-scan-test: jj unavailable — jj case skipped\n'; exit 0; }
    seed_repo jj
    out=$(env -u CI substrate-engine gate --update-baseline 2>&1) || fail "jj: baseline not green: $out"
    jj commit -m 'feat: seed' >/dev/null 2>&1
    battery jj

    jj commit -m 'chore: post-battery state' >/dev/null 2>&1
    mv components/x.sh components/renamed.sh
    printf '# we narrate after the rename\n# and we keep narrating here\n' >> components/renamed.sh
    jj diff --summary --no-pager | grep -q ' => ' || fail "jj emitted no rename summary — brace parser untested"
    err=$(mktemp)
    run_scan "$err"
    grep -q 'components/renamed.sh' "$err" || fail "jj: renamed path not resolved from brace summary: $(cat "$err")"

    jj commit -m 'chore: rename settled' >/dev/null 2>&1
    mv components lib
    printf '# we narrate inside the moved dir\n# and we narrate once more\n' >> lib/renamed.sh
    mkdir -p "$T/jj-summary-bin"
    cat > "$T/jj-summary-bin/jj" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
[ "$#" -eq 3 ] || exit 2
[ "$1" = diff ] || exit 2
[ "$2" = --summary ] || exit 2
[ "$3" = --no-pager ] || exit 2
printf 'R {components => lib}/renamed.sh\n'
SH
    chmod +x "$T/jj-summary-bin/jj"
    (
        export PATH="$T/jj-summary-bin:$PATH"
        run_scan "$err"
    )
    rc=$?
    [ "$rc" -eq 2 ] || fail "jj: prefix-brace scan exited $rc, want 2: $(cat "$err")"
    grep -q 'lib/renamed.sh' "$err" || fail "jj: dir-renamed path not resolved from prefix-brace summary: $(cat "$err")"
    rm -f "$err"
) || exit 1

printf 'changed-scan-test: git + jj batteries green (clean, slop, memo, content-key, untracked, protected, rename)\n'
