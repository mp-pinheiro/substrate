#!/usr/bin/env bash
# Agent checkpoint transaction: exact owned paths -> green gate -> tighter baseline -> local commit.
set -uo pipefail

SUBSTRATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SUBSTRATE_DIR/.." && pwd)"
cd "$REPO_ROOT" || exit 2
[ -f "$SUBSTRATE_DIR/receipt-lib.sh" ] \
    || { printf 'checkpoint blocked: receipt runtime missing — run: substrate update --apply\n' >&2; exit 2; }
# shellcheck source=./receipt-lib.sh
source "$SUBSTRATE_DIR/receipt-lib.sh"

unset SUBSTRATE_DEV_MODE

message=""
session=""
json=0
paths=()
accept=()
accept_csv=""
reason=""
usage() {
    printf 'usage: %s --message "type(scope): subject" [--session <id> | --path <repo-relative-path> ...] [--accept-regression=<metric>[,<metric>] --reason <text>] [--json]\n' "$0" >&2
    exit 2
}
SAVED_ARGS=("$@")
while [ "$#" -gt 0 ]; do
    case "$1" in
        --message) [ "$#" -ge 2 ] || usage; message="$2"; shift 2 ;;
        --path) [ "$#" -ge 2 ] || usage; paths+=("$2"); shift 2 ;;
        --session) [ "$#" -ge 2 ] || usage; session="$2"; shift 2 ;;
        --accept-regression)
            printf 'checkpoint blocked: --accept-regression requires the keyed form: --accept-regression=<metric>[,<metric>]\n' >&2
            exit 2 ;;
        --accept-regression=*)
            accept_csv="${1#--accept-regression=}"
            [ -n "$accept_csv" ] \
                || { printf 'checkpoint blocked: --accept-regression= needs at least one metric\n' >&2; exit 2; }
            shift ;;
        --reason) [ "$#" -ge 2 ] || usage; reason="$2"; shift 2 ;;
        --json) json=1; shift ;;
        *) usage ;;
    esac
done

conv='^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([^)]+\))?!?: [^[:space:]]'
[ -n "$message" ] && printf '%s\n' "$message" | grep -Eq "$conv" \
    || { printf 'checkpoint blocked: message must follow Conventional Commits — type(scope): subject\n' >&2; exit 2; }

[ -z "$accept_csv" ] || [ -n "$reason" ] \
    || { printf 'checkpoint blocked: --accept-regression requires --reason "<text>" — the justification is committed to substrate-baseline.json\n' >&2; exit 2; }
[ -n "$accept_csv" ] || [ -z "$reason" ] \
    || { printf 'checkpoint blocked: --reason applies only to --accept-regression\n' >&2; exit 2; }

source "$SUBSTRATE_DIR/engine-shim.sh"
ENGINE_MODE="${SUBSTRATE_ENGINE:-auto}"
if [ "$ENGINE_MODE" = "bash" ]; then
    :
elif substrate_engine_supports checkpoint; then
    if [ "$ENGINE_MODE" = "go" ] || [ "$ENGINE_MODE" = "auto" ]; then
        ${SUBSTRATE_ENGINE_BIN:-substrate-engine} checkpoint "${SAVED_ARGS[@]}"
        rc=$?
        [ "$rc" -eq 2 ] && { printf 'engine checkpoint returned unknown-verb after capability probe\n' >&2; exit 2; }
        exit "$rc"
    fi
elif [ "$ENGINE_MODE" = "go" ]; then
    printf 'SUBSTRATE_ENGINE=go but no substrate-engine binary found or its capabilities probe failed\n' >&2
    exit 2
fi
[ -n "$accept_csv" ] && accept=("--accept-regression=$accept_csv" "--reason=$reason")
[ -x .substrate/gate.sh ] && [ -x .substrate/hooks/protect-paths.sh ] \
    || { printf 'checkpoint blocked: vendored Substrate runtime is incomplete — run: substrate update --apply\n' >&2; exit 2; }
[ -f substrate-baseline.json ] \
    || { printf 'checkpoint blocked: establish initial debt explicitly with: substrate baseline\n' >&2; exit 2; }

vcs=git
if [ -e .jj ] && command -v jj >/dev/null 2>&1 \
    && jj_root=$(jj root 2>/dev/null) && [ "$jj_root" = "$REPO_ROOT" ]; then
    vcs=jj
fi
if git_dir=$(git rev-parse --git-common-dir 2>/dev/null); then
    case "$git_dir" in
        /*) metadata_dir="$git_dir" ;;
        *) metadata_dir="$REPO_ROOT/$git_dir" ;;
    esac
elif [ "$vcs" = jj ] && [ -d .jj ]; then
    metadata_dir="$REPO_ROOT/.jj"
else
    printf 'checkpoint blocked: no Git or Jujutsu repository metadata found\n' >&2
    exit 2
fi
lock="$metadata_dir/substrate-checkpoint.lock"
if ! mkdir "$lock" 2>/dev/null; then
    printf 'checkpoint blocked: another checkpoint owns %s\n' "$lock" >&2
    exit 2
fi

requested_file=$(mktemp)
current_file=$(mktemp)
leftover_file=$(mktemp)
baseline_backup=$(mktemp)
candidate=""
archive=""
baseline_mode=$(stat -c '%a' substrate-baseline.json 2>/dev/null || printf '644')
cp substrate-baseline.json "$baseline_backup" || exit 2
baseline_changed=0
committed=0
cleanup() {
    if [ "$baseline_changed" -eq 1 ] && [ "$committed" -eq 0 ]; then
        staged=$(mktemp substrate-baseline.json.XXXXXX 2>/dev/null || true)
        if [ -n "${staged:-}" ] && cp "$baseline_backup" "$staged" 2>/dev/null; then
            chmod "$baseline_mode" "$staged" 2>/dev/null || true
            mv -f "$staged" substrate-baseline.json 2>/dev/null || true
        fi
    fi
    rm -f "$requested_file" "$current_file" "$leftover_file" "$baseline_backup"
    [ -z "$archive" ] || rm -f "$archive"
    [ -z "$candidate" ] || rm -rf "$candidate"
    rmdir "$lock" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

if [ -n "$session" ]; then
    [ -x .substrate/hooks/agent-lifecycle.sh ] \
        || { printf 'checkpoint blocked: Claude lifecycle runtime is unavailable\n' >&2; exit 2; }
    if ! ownership=$(.substrate/hooks/agent-lifecycle.sh verify "$session"); then
        exit 2
    fi
    mapfile -t paths < <(jq -r '.paths[]' <<< "$ownership")
fi
[ "${#paths[@]}" -gt 0 ] \
    || { printf 'checkpoint blocked: no agent-owned paths were supplied\n' >&2; exit 2; }

changed_paths() {
    if [ "$vcs" = jj ]; then
        jj diff --name-only | LC_ALL=C sort -u
    else
        {
            git diff --name-only --diff-filter=ACDMRTUXB HEAD --
            git ls-files --others --exclude-standard
        } | LC_ALL=C sort -u
    fi
}

normalized=()
declare -A seen=()
for path in "${paths[@]}"; do
    path="${path#./}"
    substrate_safe_path "$path" \
        || { printf 'checkpoint blocked: unsafe path: %s\n' "$path" >&2; exit 2; }
    if [ -n "${seen[$path]:-}" ]; then
        continue
    fi
    if ! jq -n --arg path "$path" '{tool_input: {file_path: $path}}' \
        | .substrate/hooks/protect-paths.sh >/dev/null; then
        printf 'checkpoint blocked: agent-owned path is governed: %s\n' "$path" >&2
        exit 2
    fi
    seen[$path]=1
    normalized+=("$path")
done
printf '%s\n' "${normalized[@]}" | LC_ALL=C sort -u > "$requested_file"
changed_paths > "$current_file"
missing=$(LC_ALL=C comm -23 "$requested_file" "$current_file")
if [ -n "$missing" ]; then
    printf 'checkpoint blocked: supplied paths are not pending working-copy changes:\n%s\n' "$missing" >&2
    exit 2
fi
LC_ALL=C comm -13 "$requested_file" "$current_file" > "$leftover_file"

if [ ! -s "$leftover_file" ]; then
    if ! gate_output=$(.substrate/gate.sh --tighten "${accept[@]}" 2>&1); then
        printf '%s\n' "$gate_output" >&2
        printf 'checkpoint blocked: gate or baseline tightening failed\n' >&2
        exit 1
    fi
else
    # Path-scoped mode: gate the exact commit tree (base revision + owned
    # paths) in an isolated candidate so unowned pending work can neither
    # fail nor sneak into the agent's commit. gate:allow-comment
    if grep -qx 'substrate-baseline.json' "$leftover_file"; then
        printf 'checkpoint blocked: substrate-baseline.json carries changes outside agent ownership — resolve it before a path-scoped checkpoint\n' >&2
        exit 2
    fi
    base=$(current_gate_revision)
    if [ -z "$base" ] || ! git cat-file -e "$base^{commit}" 2>/dev/null; then
        printf 'checkpoint blocked: path-scoped checkpoint needs git object access to revision %s\n' "${base:-unknown}" >&2
        exit 2
    fi
    candidate=$(mktemp -d) || exit 2
    archive=$(mktemp) || exit 2
    if ! git archive --format=tar --output="$archive" "$base" \
        || ! tar -xf "$archive" -C "$candidate"; then
        printf 'checkpoint blocked: could not stage the candidate tree from %s\n' "$base" >&2
        exit 2
    fi
    while IFS= read -r path; do
        if [ -e "$path" ] || [ -L "$path" ]; then
            mkdir -p "$candidate/$(dirname "$path")" || exit 2
            cp -P --preserve=mode "$path" "$candidate/$path" || exit 2
        else
            rm -f "$candidate/$path"
        fi
    done < "$requested_file"
    [ -x "$candidate/.substrate/gate.sh" ] \
        || { printf 'checkpoint blocked: revision %s does not carry the vendored gate runtime\n' "$base" >&2; exit 2; }
    if ! git -C "$candidate" init -q --initial-branch=main \
        || ! git -C "$candidate" config user.name substrate-checkpoint \
        || ! git -C "$candidate" config user.email substrate@localhost \
        || ! git -C "$candidate" add -f -A \
        || ! git -C "$candidate" commit -q --allow-empty -m 'chore: seed checkpoint candidate'; then
        printf 'checkpoint blocked: candidate repository staging failed\n' >&2
        exit 2
    fi
    if ! gate_output=$(cd "$candidate" && unset SUBSTRATE_FILE_LIST && .substrate/gate.sh --tighten "${accept[@]}" 2>&1); then
        printf '%s\n' "$gate_output" >&2
        printf 'checkpoint blocked: gate failed for the agent-owned paths (unowned pending work was excluded)\n' >&2
        exit 1
    fi
    if ! cmp -s "$candidate/substrate-baseline.json" substrate-baseline.json; then
        staged=$(mktemp substrate-baseline.json.XXXXXX) || exit 2
        cp "$candidate/substrate-baseline.json" "$staged" || exit 2
        chmod "$baseline_mode" "$staged" || exit 2
        mv -f "$staged" substrate-baseline.json || exit 2
    fi
fi
printf '%s\n' "$gate_output"
commit_paths=("${normalized[@]}")
if ! cmp -s "$baseline_backup" substrate-baseline.json; then
    baseline_changed=1
    commit_paths+=(substrate-baseline.json)
fi

if [ "$vcs" = jj ]; then
    if ! commit_output=$(jj commit --message "$message" -- "${commit_paths[@]}" 2>&1); then
        printf '%s\ncheckpoint failed: jj commit rejected the transaction\n' "$commit_output" >&2
        exit 1
    fi
    commit=$(jj log -r @- --no-graph -T 'commit_id' 2>/dev/null)
else
    if ! git add -- "${commit_paths[@]}"; then
        printf 'checkpoint failed: git could not stage the owned paths\n' >&2
        exit 1
    fi
    if ! commit_output=$(git commit --only -m "$message" -- "${commit_paths[@]}" 2>&1); then
        git reset --quiet -- "${commit_paths[@]}" 2>/dev/null || true
        printf '%s\ncheckpoint failed: git commit rejected the transaction\n' "$commit_output" >&2
        exit 1
    fi
    commit=$(git rev-parse HEAD 2>/dev/null)
fi
committed=1
printf '%s\n' "$commit_output"

changed_paths > "$current_file"
if ! cmp -s "$current_file" "$leftover_file"; then
    printf 'checkpoint incomplete: post-commit pending paths diverge from the expected remainder\n' >&2
    diff "$leftover_file" "$current_file" >&2 || true
    exit 1
fi
if [ ! -s "$leftover_file" ]; then
    if ! verify_output=$(.substrate/gate.sh 2>&1); then
        printf '%s\ncheckpoint incomplete: post-commit gate failed; receipt not written\n' "$verify_output" >&2
        exit 1
    fi
    printf '%s\n' "$verify_output"
fi

receipt=$(write_gate_receipt checkpoint "$commit" "$vcs" "$session" "$accept_csv") \
    || { printf 'checkpoint incomplete: exact-state receipt write failed\n' >&2; exit 1; }
if [ -n "$session" ] && ! .substrate/hooks/agent-lifecycle.sh complete "$session" "$commit"; then
    printf 'checkpoint incomplete: commit exists but Claude lifecycle receipt update failed\n' >&2
    exit 1
fi

if [ "$json" -eq 1 ]; then
    printf '%s\n' "$receipt"
else
    printf 'checkpoint complete: %s (%s)\n' "${commit:0:12}" "$message"
fi
if [ -s "$leftover_file" ]; then
    printf 'checkpoint left unowned pending paths in place:\n' >&2
    while IFS= read -r path; do printf '  %s\n' "$path"; done < "$leftover_file" >&2
fi
