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

message=""
session=""
json=0
paths=()
usage() {
    printf 'usage: %s --message "type(scope): subject" [--session <id> | --path <repo-relative-path> ...] [--json]\n' "$0" >&2
    exit 2
}
while [ "$#" -gt 0 ]; do
    case "$1" in
        --message) [ "$#" -ge 2 ] || usage; message="$2"; shift 2 ;;
        --path) [ "$#" -ge 2 ] || usage; paths+=("$2"); shift 2 ;;
        --session) [ "$#" -ge 2 ] || usage; session="$2"; shift 2 ;;
        --json) json=1; shift ;;
        *) usage ;;
    esac
done

conv='^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([^)]+\))?!?: [^[:space:]]'
[ -n "$message" ] && printf '%s\n' "$message" | grep -Eq "$conv" \
    || { printf 'checkpoint blocked: message must follow Conventional Commits — type(scope): subject\n' >&2; exit 2; }
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
baseline_backup=$(mktemp)
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
    rm -f "$requested_file" "$current_file" "$baseline_backup"
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
    case "$path" in
        ''|/*|..|../*|*/../*|*/..|-*)
            printf 'checkpoint blocked: unsafe path: %s\n' "$path" >&2
            exit 2 ;;
    esac
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
if ! cmp -s "$requested_file" "$current_file"; then
    printf 'checkpoint blocked: supplied ownership does not exactly match the working copy\n' >&2
    diff "$requested_file" "$current_file" >&2 || true
    exit 2
fi

if ! gate_output=$(.substrate/gate.sh --tighten 2>&1); then
    printf '%s\n' "$gate_output" >&2
    printf 'checkpoint blocked: gate or baseline tightening failed\n' >&2
    exit 1
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
if [ -s "$current_file" ]; then
    printf 'checkpoint incomplete: working copy is not clean after commit\n' >&2
    cat "$current_file" >&2
    exit 1
fi
if ! verify_output=$(.substrate/gate.sh 2>&1); then
    printf '%s\ncheckpoint incomplete: post-commit gate failed; receipt not written\n' "$verify_output" >&2
    exit 1
fi
printf '%s\n' "$verify_output"

receipt=$(write_gate_receipt checkpoint "$commit" "$vcs" "$session") \
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
