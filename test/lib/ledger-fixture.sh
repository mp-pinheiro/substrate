# Deterministic fixture behind the session-ledger golden vectors (amendment
# A8: non-ASCII and invalid-UTF-8 paths). Sourced only; callers set KIT_ROOT
# and LEDGER_LABEL, pin jq on PATH, then call ledger_assert_toolchain.

LEDGER_DIR="$KIT_ROOT/test/golden/ledger"
LEDGER_JQ="$KIT_ROOT/test/.toolchain/bin/jq"
LEDGER_JQ_VERSION=jq-1.7.1
LEDGER_VECTORS=(jj-nonascii.json git-invalid-utf8.json)
LEDGER_MANIFEST=manifest.json

ledger_fail() {
    printf '\033[0;31m[XX]\033[0m %s: %s\n' "${LEDGER_LABEL:-ledger}" "$*" >&2
    exit 1
}

ledger_ok() {
    printf '\033[0;32m[ok]\033[0m %s: %s\n' "${LEDGER_LABEL:-ledger}" "$*"
}

ledger_assert_toolchain() {
    command -v jj >/dev/null 2>&1 || ledger_fail "jj is required"
    [ -x "$LEDGER_JQ" ] || ledger_fail "pinned jq missing at $LEDGER_JQ"
    local have
    have=$("$LEDGER_JQ" --version 2>/dev/null) || ledger_fail "pinned jq unrunnable"
    [ "$have" = "$LEDGER_JQ_VERSION" ] || ledger_fail "pinned jq is $have, want $LEDGER_JQ_VERSION"
    case "$BASH_VERSION" in
        5.*) ;;
        *) ledger_fail "captured under bash $BASH_VERSION, vectors assume 5.x" ;;
    esac
}

# masks a repo-root prefix, hex revisions/hashes, and this fixture's own
# session id so the frozen bytes carry no run-local noise
ledger_mask() {
    "$LEDGER_JQ" -c --arg repo "$1" --arg session "$2" '
        walk(if type == "string" then
            gsub($repo; "<REPO>")
            | gsub($session; "<SESSION>")
            | gsub("^[0-9a-f]{40}$"; "<REV40>")
            | gsub("^[0-9a-f]{64}$"; "<SHA256>")
        else . end)' <<< "$3"
}

ledger_new_template() {
    local template="$1"
    mkdir -p "$template" || return 1
    (
        cd "$template" || exit 1
        git init -q --initial-branch=main || exit 1
        printf 'seed\n' > README.md || exit 1
        "$KIT_ROOT/bin/substrate" init --profile base || exit 1
        rm -f .substrate/report.sh || exit 1
    ) >/dev/null 2>&1
    [ -f "$template/.substrate/engine-shim.sh" ]
}

ledger_lifecycle() {
    local repo="$1" session="$2" action="$3" payload="${4:-}" engine="${5:-bash}"
    printf '%s' "$payload" \
        | ( cd "$repo" && env SUBSTRATE_ENGINE="$engine" bash .substrate/hooks/agent-lifecycle.sh "$action" )
}

# jj leg: non-ASCII paths through the hook's default vcs. jj renders them raw.
ledger_capture_jj_nonascii() {
    local out="$1" template="$2" engine="${3:-bash}" repo session ledger
    repo="$(mktemp -d)" || return 1
    cp -R "$template" "$repo/r" || return 1
    repo="$repo/r"
    session=golden-ledger-jj
    (
        cd "$repo" || exit 1
        export JJ_USER=substrate JJ_EMAIL=substrate@localhost
        jj git init --colocate . || exit 1
        printf 'plain\n' > plain.txt
        printf 'accent\n' > "café.txt"
        printf 'cjk\n' > "日本語.md"
        jj commit -m 'chore: seed ledger fixture' || exit 1
    ) >/dev/null 2>&1 || return 1
    ledger_lifecycle "$repo" "$session" start "{\"session_id\":\"$session\"}" "$engine" >/dev/null 2>&1 || return 1
    printf 'edit\n' >> "$repo/café.txt" || return 1
    printf 'edit\n' >> "$repo/plain.txt" || return 1
    printf 'new\n' > "$repo/nouveau-é.txt" || return 1
    ledger_lifecycle "$repo" "$session" observe "{\"session_id\":\"$session\"}" "$engine" >/dev/null 2>&1 || return 1
    ledger="$repo/.git/substrate/agent-sessions/$session.json"
    [ -f "$ledger" ] || return 1
    ledger_mask "$repo" "$session" "$(cat "$ledger")" > "$out" || return 1
}

# git leg: an invalid-UTF-8 filename. jj refuses to snapshot it at all, so
# this leg deliberately stays on plain git to observe git's own byte handling.
ledger_capture_git_invalid_utf8() {
    local out="$1" template="$2" engine="${3:-bash}" repo session ledger badname
    repo="$(mktemp -d)" || return 1
    cp -R "$template" "$repo/r" || return 1
    repo="$repo/r"
    session=golden-ledger-git
    (
        cd "$repo" || exit 1
        git config user.email substrate@localhost || exit 1
        git config user.name substrate || exit 1
        printf 'plain\n' > plain.txt || exit 1
        git add -A || exit 1
        git commit -qm 'chore: seed ledger fixture' || exit 1
    ) >/dev/null 2>&1 || return 1
    ledger_lifecycle "$repo" "$session" start "{\"session_id\":\"$session\"}" "$engine" >/dev/null 2>&1 || return 1
    badname="$repo/$(printf 'bad-\xff-name.txt')"
    printf 'invalid utf8 name\n' > "$badname" || return 1
    ledger_lifecycle "$repo" "$session" observe "{\"session_id\":\"$session\"}" "$engine" >/dev/null 2>&1 || return 1
    ledger="$repo/.git/substrate/agent-sessions/$session.json"
    [ -f "$ledger" ] || return 1
    ledger_mask "$repo" "$session" "$(cat "$ledger")" > "$out" || return 1
}

ledger_regenerate() {
    local scratch="$1" dest="$2" engine="${3:-bash}"
    local template="$scratch/template"
    mkdir -p "$dest" || return 1
    ledger_new_template "$template" || return 1
    ledger_capture_jj_nonascii "$dest/jj-nonascii.json" "$template" "$engine" || return 1
    ledger_capture_git_invalid_utf8 "$dest/git-invalid-utf8.json" "$template" "$engine" || return 1
}

ledger_file_sha256() {
    sha256sum "$1" 2>/dev/null | cut -d ' ' -f 1
}

ledger_write_manifest() {
    local dest="$1" out="$1/$LEDGER_MANIFEST" v hash entries=()
    for v in "${LEDGER_VECTORS[@]}"; do
        hash=$(ledger_file_sha256 "$dest/$v") || return 1
        entries+=("{\"file\":\"$v\",\"sha256\":\"$hash\"}")
    done
    "$LEDGER_JQ" -cn --arg bash "$BASH_VERSION" --arg jq "$LEDGER_JQ_VERSION" \
        --argjson vectors "[$(IFS=,; printf '%s' "${entries[*]}")]" \
        '{bash:$bash,jq:$jq,vectors:$vectors}' > "$out"
}

ledger_compare_vectors() {
    local dest="$1" v
    for v in "${LEDGER_VECTORS[@]}"; do
        [ -f "$LEDGER_DIR/$v" ] || ledger_fail "no committed vector for $v — capture it first"
        cmp -s "$LEDGER_DIR/$v" "$dest/$v" \
            || ledger_fail "$v diverged from the committed vector — a real semantic move, or a stale capture"
        ledger_ok "$v byte-identical"
    done
}
