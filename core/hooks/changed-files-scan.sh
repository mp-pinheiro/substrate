#!/usr/bin/env bash
# PostToolUse (every mutating tool): ratchet what actually changed in the
# tree, not what the tool declared, so bash/eval writes are covered; flag
# protected_paths hits the write hook could not see. stderr report, exit 2.
set -uo pipefail
umask 077

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBSTRATE_DIR="$(cd "$HOOK_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SUBSTRATE_DIR/.." && pwd)"
CONFIG="$REPO_ROOT/substrate.json"

cd "$REPO_ROOT" || exit 0
[ -t 0 ] || cat >/dev/null 2>&1 || true
[ -f "$CONFIG" ] || exit 0

# rename summaries keep only the destination: the source is gone from the tree
resolve_rename() {
    local p="$1" pre mid post
    case "$p" in
        *'{'*' => '*'}'*)
            pre="${p%%\{*}"
            mid="${p#*\{}"
            mid="${mid%%\}*}"
            post="${p#*\}}"
            p="${pre}${mid##* => }${post}"
            p="${p//\/\//\/}"
            ;;
        *' => '*) p="${p##* => }" ;;
        *' -> '*) p="${p##* -> }" ;;
    esac
    printf '%s' "$p"
}

changed=()
if [ -d .jj ]; then
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        status="${line%% *}"
        path="${line#* }"
        [ "$status" = "D" ] && continue
        changed+=("$(resolve_rename "$path")")
    done < <(jj diff --summary --no-pager 2>/dev/null)
else
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        status="${line:0:2}"
        path="${line:3}"
        case "$status" in *D*) continue ;; esac
        changed+=("$(resolve_rename "$path")")
    done < <(git status --porcelain -uall 2>/dev/null)
fi
[ ${#changed[@]} -eq 0 ] && exit 0

# pass-only memo; baseline+config signatures namespace it so allowance edits invalidate it wholesale
sig() { stat -c '%.9Y:%s' "$1" 2>/dev/null || printf '0'; }
ns=$(printf '%s|%s|%s' "$REPO_ROOT" "$(sig substrate-baseline.json)" "$(sig "$CONFIG")" | sha256sum)
CACHE="${TMPDIR:-/tmp}/substrate-scan-$(id -u)-${ns:0:16}"
if [ -f "$CACHE" ] && [ "$(wc -l < "$CACHE")" -gt 4096 ]; then
    : > "$CACHE" || true
fi

mapfile -t protected < <(jq -r '(.protected_paths // [])[]' "$CONFIG" 2>/dev/null)
mapfile -t unscanned < <(jq -r '(.unscanned // [])[]' "$CONFIG" 2>/dev/null)

nl=$'\n'
report=""
for path in "${changed[@]}"; do
    flagged=0
    for g in ${protected[@]+"${protected[@]}"}; do
        # shellcheck disable=SC2254 # globs are the contract here
        case "$path" in
            $g)
                report+="protected path written outside the write hook: $path — revert it and edit the source instead${nl}"
                flagged=1
                break
                ;;
        esac
    done
    [ "$flagged" -eq 1 ] && continue
    [ -f "$path" ] || continue
    skip=0
    for g in ${unscanned[@]+"${unscanned[@]}"}; do
        # shellcheck disable=SC2254 # globs are the contract here
        case "$path" in
            $g)
                skip=1
                break
                ;;
        esac
    done
    [ "$skip" -eq 1 ] && continue
    key="$path|$(sig "$path")"
    if [ -f "$CACHE" ] && grep -qxF "$key" "$CACHE" 2>/dev/null; then
        continue
    fi
    if out=$("$SUBSTRATE_DIR/comment-ratchet.sh" "$path" 2>&1); then
        printf '%s\n' "$key" >> "$CACHE" 2>/dev/null || true
    else
        report+="${out}${nl}"
    fi
done

[ -n "$report" ] || exit 0
printf '%s' "$report" >&2
exit 2
