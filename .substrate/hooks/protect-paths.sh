#!/usr/bin/env bash
# PreToolUse (Write|Edit): blocks symlink writes, the baseline, .substrate/,
# governance docs, and substrate.json protected_paths globs. Fail closed: a
# corrupt substrate.json blocks writes until fixed.
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBSTRATE_DIR="$(cd "$HOOK_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SUBSTRATE_DIR/.." && pwd)"
CONFIG="$REPO_ROOT/substrate.json"

input=$(cat)
path=$(jq -r '.tool_input.file_path // empty' <<< "$input")
[ -n "$path" ] || exit 0

if [ -f "$CONFIG" ] && ! jq -e . "$CONFIG" >/dev/null 2>&1; then
    echo "blocked: substrate.json is corrupt — fix it before writing anything else" >&2
    exit 2
fi
if [ -f "$CONFIG" ] && ! jq -e '(.contracts // []) | all((.name | type == "string") and (.regen | type == "string") and (.paths | type == "array"))' "$CONFIG" >/dev/null 2>&1; then
    echo "blocked: substrate.json contracts entries need name/regen/paths — fix the config" >&2
    exit 2
fi

abs="$path"
case "$abs" in
    /*) ;;
    *) abs="$REPO_ROOT/$abs" ;;
esac

if [ -L "$abs" ]; then
    target=$(readlink -f "$abs" 2>/dev/null || readlink "$abs")
    echo "blocked: $path is a symlink to $target — writing through it clobbers the target; edit the target explicitly if that is intended" >&2
    exit 2
fi

rel="$path"
case "$rel" in
    "$REPO_ROOT"/*) rel="${rel#"$REPO_ROOT"/}" ;;
esac
real=$(readlink -f "$abs" 2>/dev/null || printf '%s' "$abs")
case "$real" in
    "$REPO_ROOT"/*) real="${real#"$REPO_ROOT"/}" ;;
    "$REPO_ROOT") real="." ;;
    *)
        echo "blocked: $path resolves outside the repo ($real) — a parent directory is a symlink" >&2
        exit 2 ;;
esac

check_hard() {
    case "$1" in
        substrate-baseline.json)
            echo "blocked: baseline changes only via the gate (--update-baseline)" >&2
            exit 2 ;;
        */substrate-baseline.json)
            echo "blocked: $1 is not the repo baseline, but that basename is governed anywhere in the tree — the rule is name-based so it can rule on paths whose parents do not exist yet; rename the file if it is not a substrate baseline" >&2
            exit 2 ;;
        .substrate/*|*/.substrate/*)
            echo "blocked: $1 is vendored substrate core — change the kit and run: substrate update" >&2
            exit 2 ;;
        CLAUDE.md|*/CLAUDE.md)
            echo "blocked: CLAUDE.md is the governance doc — propose the edit to the user instead" >&2
            exit 2 ;;
    esac
}
check_hard "$rel"
check_hard "$real"

if [ -f "$CONFIG" ]; then
    while IFS= read -r g; do
        [ -n "$g" ] || continue
        # shellcheck disable=SC2254 # globs are the contract here
        case "$rel" in
            $g)
                echo "blocked: $rel is protected by substrate.json protected_paths" >&2
                exit 2 ;;
        esac
        # shellcheck disable=SC2254 # globs are the contract here
        case "$real" in
            $g)
                echo "blocked: $real is protected by substrate.json protected_paths" >&2
                exit 2 ;;
        esac
    done < <(jq -r '(.protected_paths // [])[]' "$CONFIG")
    # contract paths are literal files or directories, not globs — the drift
    # check diffs the same strings, so both consumers share one semantic
    while IFS= read -r g; do
        [ -n "$g" ] || continue
        for candidate in "$rel" "$real"; do
            case "$candidate" in
                "$g" | "$g"/*)
                    echo "blocked: $candidate is generated from a contract — edit the contract source; the gate regenerates (substrate.json contracts)" >&2
                    exit 2 ;;
            esac
        done
    done < <(jq -r '(.contracts // [])[] | (.paths // [])[]' "$CONFIG")
fi
exit 0
