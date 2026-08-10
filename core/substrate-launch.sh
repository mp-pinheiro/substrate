#!/usr/bin/env bash
# User-level Claude hook dispatcher (~/.claude/hooks/): resolves the repo from
# the tool's target path (else the session root), walks up to the vendored
# hook, exits 0 where none exists — safe to register machine-globally.
# Usage: substrate-launch.sh <hook-name> [hook-args...]  (stdin payload passes through)
set -uo pipefail

hook="${1:-}"
shift || true
hook_args=("$@")
[ -n "$hook" ] || exit 0
case "$hook" in
    */* | .*) exit 0 ;;
esac
hook="${hook%.sh}"
normalize_absolute_path() {
    local input="$1" part out="" i n=0
    local stack=()
    IFS='/' read -r -a parts <<< "$input"
    for part in ${parts[@]+"${parts[@]}"}; do
        case "$part" in
            "" | .) continue ;;
            ..)
                if [ "$n" -gt 0 ]; then
                    n=$((n - 1))
                    unset 'stack[n]'
                fi
                ;;
            *)
                stack[n]="$part"
                n=$((n + 1))
                ;;
        esac
    done
    for ((i = 0; i < n; i++)); do
        out="$out/${stack[$i]}"
    done
    printf '%s\n' "${out:-/}"
}

project_hook_registered() {
    local settings="$1" name="$2"
    local engine="substrate-engine hook $name"
    local legacy="bash \"\${CLAUDE_PROJECT_DIR:-.}/.substrate/hooks/$name.sh\""
    jq -e --arg engine "$engine" --arg legacy "$legacy" '
        [
            (.hooks.PreToolUse // [])[],
            (.hooks.PostToolUse // [])[],
            (.hooks.SessionStart // [])[],
            (.hooks.Stop // [])[],
            (.hooks.SessionEnd // [])[]
        ]
        | any(.[] | .hooks[]?;
            (.type == "command")
            and (((.command // "") == $engine)
                 or ((.command // "") | startswith($engine + " "))
                 or ((.command // "") | startswith($legacy))))
    ' "$settings" >/dev/null 2>&1
}


payload=""
[ -t 0 ] || payload=$(cat)

session="$(cd "${CLAUDE_PROJECT_DIR:-$PWD}" 2>/dev/null && pwd -P)" || session=""
[ -n "$session" ] || exit 0
target=""
if [ -n "$payload" ] && command -v jq >/dev/null 2>&1; then
    target=$(printf '%s' "$payload" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null) || target=""
fi

if [ -n "$target" ]; then
    case "$target" in
        /*) dir=$(normalize_absolute_path "$(dirname "$target")") ;;
        *) dir=$(normalize_absolute_path "$session/$(dirname "$target")") ;;
    esac
else
    dir="$session"
fi

while :; do
    if [ -f "$dir/.substrate/VERSION" ]; then
        # Stand down only for an exact project hook registration at the session root.
        if [ "$dir" = "$session" ] && [ -f "$dir/.claude/settings.json" ] \
            && project_hook_registered "$dir/.claude/settings.json" "$hook"; then
            exit 0
        fi
        cd "$dir" || exit 0
        exec substrate-engine hook "$hook" "${hook_args[@]}" <<< "$payload"
    fi
    [ "$dir" = "/" ] && exit 0
    dir="$(dirname "$dir")"
done
