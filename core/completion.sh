#!/usr/bin/env bash
# Command registry, usage rendering, and shell completions — sourced by bin/substrate.
# Single source of truth for the command surface: SUBSTRATE_COMMANDS entries are
# "name|description|words..." (words are flags/subcommands offered after the command
# name) and SUBSTRATE_FLAG_DOCS entries are "command|flag|placeholder|required|description"
# (placeholder and required may be empty; a flag ending in "=" takes its placeholder
# attached, e.g. --accept-regression=<metric>[,<metric>]). Root usage, per-command
# --help, and `substrate completion` all render from these two arrays;
# test/completion-test.sh enforces dispatch/registry/flag parity, including the
# Go-parsed maintenance flags in internal/maintenance/args.go.

SUBSTRATE_COMMANDS=(
    "bootstrap|kickstart or synchronize the current repo|--profile --vcs --force --from-worktree --checkpoint --message --accept-baseline --accept-regression= --reason --json --repo-only --help"
    "init|install the gate into a new repo|--profile --vcs --force --from-worktree --checkpoint --message --accept-baseline --accept-regression= --reason --json --repo-only --help"
    "gate|run the gate|--update-baseline --tighten --accept-regression --accept-regression= --json --deep --no-cache --print-key --help"
    "version|print the engine/kit version and channel|--help"
    "checkpoint|gate, tighten, and commit locally|--message --path --accept-regression= --reason --json --help"
    "restructure|reshape agent commits|--op --revision --message --message2 --into --path --json --help"
    "baseline|manage the ratchet baseline|--update --accept-regression --accept-regression= --reason --help"
    "doctor|config, langmap freshness, toolchain|--help"
    "verify|active OMP runtime + bounded local gate|--help"
    "update|inspect or re-vendor the engine|--apply --force --from-worktree --checkpoint --message --accept-baseline --accept-regression= --reason --json --repo-only --help"
    "engine|engine maintenance (pin: RELEASE ACTION)|pin --bin --help"
    "selftest|sandboxed negative-test battery|--help"
    "audit|execute plan acceptance oracles|--help"
    "report|advisory maintenance queue (always exits 0)|--write --refresh --help"
    "completion|print or install shell completions|bash fish zsh --install --help"
)

SUBSTRATE_FLAG_DOCS=(
    "bootstrap|--profile|<a,b>||comma-separated profiles to enable (required for a new repo)"
    "bootstrap|--vcs|<auto,git,jj>||VCS to wire: auto, git or jj (default: auto)"
    "bootstrap|--force|||adopt unmanaged files that exactly match generated output"
    "bootstrap|--from-worktree|||vendor from the kit worktree even when dirty or unpushed"
    "bootstrap|--checkpoint|||create the local commit after the transaction"
    "bootstrap|--message|<message>||Conventional Commit message (50 characters at most)"
    "bootstrap|--accept-baseline|||explicitly adopt initial debt"
    "bootstrap|--accept-regression=|<metric>[,<metric>]||accept a reviewed regression (requires --reason)"
    "bootstrap|--reason|<text>||reason recorded with --accept-regression="
    "bootstrap|--json|||accepted for transaction compatibility; the machine-readable result is the maintenance receipt"
    "bootstrap|--repo-only|||skip user-harness synchronization"
    "init|--profile|<a,b>|required|comma-separated profiles to enable"
    "init|--vcs|<auto,git,jj>||VCS to wire: auto, git or jj (default: auto)"
    "init|--force|||adopt unmanaged files that exactly match generated output"
    "init|--from-worktree|||vendor from the kit worktree even when dirty or unpushed"
    "init|--checkpoint|||create the local commit after the transaction"
    "init|--message|<message>||Conventional Commit message (50 characters at most)"
    "init|--accept-baseline|||explicitly adopt initial debt"
    "init|--accept-regression=|<metric>[,<metric>]||accept a reviewed regression (requires --reason)"
    "init|--reason|<text>||reason recorded with --accept-regression="
    "init|--json|||accepted for transaction compatibility; the machine-readable result is the maintenance receipt"
    "init|--repo-only|||skip user-harness synchronization"
    "gate|--update-baseline|||write emitted baseline values on a green gate"
    "gate|--tighten|||lower existing ratchet ceilings after a green run"
    "gate|--accept-regression|||accept a reviewed regression (requires --reason)"
    "gate|--accept-regression=|<metric>[,<metric>]||accept reviewed regressions by key (requires --reason)"
    "gate|--json|||machine-readable gate output"
    "gate|--deep|||also scan full reachable history for secrets"
    "gate|--no-cache|||skip the cached deep secret scan (only with --deep)"
    "gate|--print-key|||print the deep-scan cache key (only with --deep)"
    "checkpoint|--message|<message>|required|Conventional Commit message for the local commit"
    "checkpoint|--path|<path>||limit the checkpoint to these pending paths"
    "checkpoint|--accept-regression=|<metric>[,<metric>]||accept a reviewed regression (requires --reason)"
    "checkpoint|--reason|<text>||reason recorded with --accept-regression="
    "checkpoint|--json|||machine-readable output"
    "restructure|--op|<split,describe,squash>|required|operation to apply"
    "restructure|--revision|<rev>|required|revision to reshape"
    "restructure|--message|<message>||Conventional Commit message for the reshaped commit"
    "restructure|--message2|<message>||second commit message (split)"
    "restructure|--into|<rev>||target revision for --op split"
    "restructure|--path|<path>||limit to these paths"
    "restructure|--json|||machine-readable output"
    "baseline|--update|||establish or rewrite the baseline from emitted values"
    "baseline|--accept-regression|||accept a reviewed regression (requires --reason)"
    "baseline|--accept-regression=|<metric>[,<metric>]||accept reviewed regressions by key (requires --reason)"
    "baseline|--reason|<text>||reason recorded with --accept-regression"
    "update|--apply|||run the vendor transaction instead of only inspecting drift"
    "update|--force|||adopt unmanaged files that exactly match generated output"
    "update|--from-worktree|||vendor from the kit worktree even when dirty or unpushed"
    "update|--checkpoint|||create the local commit after the transaction"
    "update|--message|<message>||Conventional Commit message (50 characters at most)"
    "update|--accept-baseline|||explicitly adopt initial debt"
    "update|--accept-regression=|<metric>[,<metric>]||accept a reviewed regression (requires --reason)"
    "update|--reason|<text>||reason recorded with --accept-regression="
    "update|--json|||accepted for transaction compatibility; the machine-readable result is the maintenance receipt"
    "update|--repo-only|||skip user-harness synchronization"
    "engine|pin|||pin the engine to a release (RELEASE ACTION)"
    "engine|--bin|<path>||path to the substrate-engine binary to pin"
    "report|--write|||write the advisory maintenance queue"
    "report|--refresh|||atomically refresh the advisory maintenance queue"
    "completion|bash|||print the bash completion script"
    "completion|fish|||print the fish completion script"
    "completion|zsh|||print the zsh completion script"
    "completion|--install|||install a one-line source into the shell rc file (idempotent)"
    "bootstrap|--help|||show this help"
    "init|--help|||show this help"
    "gate|--help|||show this help"
    "version|--help|||show this help"
    "checkpoint|--help|||show this help"
    "restructure|--help|||show this help"
    "baseline|--help|||show this help"
    "doctor|--help|||show this help"
    "verify|--help|||show this help"
    "update|--help|||show this help"
    "engine|--help|||show this help"
    "selftest|--help|||show this help"
    "audit|--help|||show this help"
    "report|--help|||show this help"
    "completion|--help|||show this help"
)

registry_name()  { printf '%s' "${1%%|*}"; }
registry_desc()  { local r; r="${1#*|}"; printf '%s' "${r%%|*}"; }
registry_words() { local r; r="${1#*|}"; printf '%s' "${r#*|}"; }

# flag_field <cmd> <flag> <3=placeholder|4=required|5=description>
flag_field() {
    local e c rest f3 f4 f5
    for e in "${SUBSTRATE_FLAG_DOCS[@]}"; do
        c="${e%%|*}"; rest="${e#*|}"
        if [ "$c" = "$1" ] && [ "${rest%%|*}" = "$2" ]; then
            f3="${rest#*|}"; f3="${f3%%|*}"
            rest="${rest#*|}"; rest="${rest#*|}"
            f4="${rest%%|*}"; f5="${rest#*|}"
            case "$3" in
                3) printf '%s' "$f3" ;;
                4) printf '%s' "$f4" ;;
                5) printf '%s' "$f5" ;;
            esac
            return
        fi
    done
}
flag_doc() { flag_field "$1" "$2" 5; }
flag_ph()  { flag_field "$1" "$2" 3; }
flag_req() { flag_field "$1" "$2" 4; }

# flag_label <cmd> <flag> — "flag", "flag <ph>", or "flag=<ph>" for keyed flags
flag_label() {
    local w="$2" ph
    ph=$(flag_ph "$1" "$2")
    case "$w" in
        *=) printf '%s%s' "$w" "$ph" ;;
        *)  if [ -n "$ph" ]; then printf '%s %s' "$w" "$ph"; else printf '%s' "$w"; fi ;;
    esac
}

print_usage_root() {
    local e name desc max_name=0
    for e in "${SUBSTRATE_COMMANDS[@]}"; do
        name=$(registry_name "$e")
        [ "${#name}" -gt "$max_name" ] && max_name=${#name}
    done
    printf 'usage: substrate <command> [args]\n\nCommands:\n'
    for e in "${SUBSTRATE_COMMANDS[@]}"; do
        name=$(registry_name "$e"); desc=$(registry_desc "$e")
        printf '  %-*s  %s\n' "$max_name" "$name" "$desc"
    done
    cat <<'EOF'

Notes:
  maintenance flags: --checkpoint [--message <message>] [--accept-baseline] [--repo-only] [--json]
                     [--accept-regression=<metric>[,<metric>] --reason <text>]  move a ratcheted metric that a core change moved
  --from-worktree on bootstrap/init/update vendors from the kit worktree even when
                     it is dirty or unpushed
  run 'substrate <command> --help' for the flags of a specific command
EOF
}

print_usage_cmd() {
    local cmd="$1" e name desc words w label d req
    local syn_req="" syn_opt="" max_label=0
    for e in "${SUBSTRATE_COMMANDS[@]}"; do
        name=$(registry_name "$e")
        [ "$name" = "$cmd" ] || continue
        desc=$(registry_desc "$e"); words=$(registry_words "$e")
        for w in $words; do
            [ "$w" = "--help" ] && continue
            label=$(flag_label "$cmd" "$w")
            req=$(flag_req "$cmd" "$w")
            if [ "$req" = "required" ]; then
                syn_req="$syn_req $label"
            else
                syn_opt="$syn_opt $label"
            fi
            [ "${#label}" -gt "$max_label" ] && max_label=${#label}
        done
        printf 'usage: substrate %s%s%s\n\n%s\n\nFlags:\n' \
            "$cmd" "$syn_req" "${syn_opt:+ [${syn_opt# }]}" "$desc"
        for w in $words; do
            label=$(flag_label "$cmd" "$w")
            req=$(flag_req "$cmd" "$w")
            d=$(flag_doc "$cmd" "$w")
            [ "$req" = "required" ] && d="$d (required)"
            printf '  %-*s  %s\n' "$max_label" "$label" "$d"
        done
        return 0
    done
    return 1
}

# Escape for single-quoted zsh/fish strings: ' -> '\''
sq_escape() { printf '%s' "${1//\'/\'\\\'\'}"; }

completion_bash() {
    local e name words first=1
    printf '_substrate_completions() {\n'
    printf '    local cur cmd\n'
    printf '    cur="${COMP_WORDS[COMP_CWORD]}"\n'
    printf '    if [ "$COMP_CWORD" -eq 1 ]; then\n'
    printf '        COMPREPLY=($(compgen -W "'
    for e in "${SUBSTRATE_COMMANDS[@]}"; do
        [ "$first" -eq 1 ] || printf ' '
        printf '%s' "$(registry_name "$e")"
        first=0
    done
    printf '" -- "$cur"))\n'
    printf '        return\n'
    printf '    fi\n'
    printf '    cmd="${COMP_WORDS[1]}"\n'
    printf '    case "$cmd" in\n'
    for e in "${SUBSTRATE_COMMANDS[@]}"; do
        name=$(registry_name "$e"); words=$(registry_words "$e")
        [ -n "$words" ] || continue
        printf '        %s) COMPREPLY=($(compgen -W "%s" -- "$cur")) ;;\n' "$name" "$words"
    done
    printf '    esac\n'
    printf '}\n'
    printf 'complete -F _substrate_completions substrate\n'
}

completion_zsh() {
    local e name desc words w
    printf '#compdef substrate\n\n'
    printf '_substrate() {\n'
    printf '    local -a commands\n'
    printf '    commands=(\n'
    for e in "${SUBSTRATE_COMMANDS[@]}"; do
        name=$(registry_name "$e"); desc=$(registry_desc "$e")
        printf "        '%s:%s'\n" "$(sq_escape "$name")" "$(sq_escape "$desc")"
    done
    printf '    )\n'
    printf '    if (( CURRENT == 2 )); then\n'
    printf '        _describe "command" commands\n'
    printf '        return\n'
    printf '    fi\n'
    printf '    case "${words[2]}" in\n'
    for e in "${SUBSTRATE_COMMANDS[@]}"; do
        name=$(registry_name "$e"); words=$(registry_words "$e")
        [ -n "$words" ] || continue
        printf '        %s)\n' "$name"
        printf '            local -a args\n'
        printf '            args=(\n'
        for w in $words; do
            printf "                '%s:%s'\n" "$(sq_escape "$w")" "$(sq_escape "$(flag_doc "$name" "$w")")"
        done
        printf '            )\n'
        printf '            _describe "argument" args\n'
        printf '            ;;\n'
    done
    printf '    esac\n'
    printf '}\n\n'
    printf 'if (( $+functions[compdef] )); then\n'
    printf '    compdef _substrate substrate\n'
    printf 'else\n'
    printf '    _substrate_register() {\n'
    printf '        if (( $+functions[compdef] )); then\n'
    printf '            compdef _substrate substrate\n'
    printf '            precmd_functions=("${precmd_functions[@]/_substrate_register}")\n'
    printf '        fi\n'
    printf '    }\n'
    printf '    precmd_functions+=(_substrate_register)\n'
    printf 'fi\n'
    printf '_substrate "$@"\n'
}

completion_fish() {
    local e name desc words w
    printf 'function __fish_substrate_needs_command\n'
    printf '    set -l cmd (commandline -opc)\n'
    printf '    test (count $cmd) -eq 1\n'
    printf 'end\n'
    for e in "${SUBSTRATE_COMMANDS[@]}"; do
        name=$(registry_name "$e"); desc=$(registry_desc "$e")
        printf "complete -c substrate -f -n __fish_substrate_needs_command -a %s -d '%s'\n" "$(sq_escape "$name")" "$(sq_escape "$desc")"
    done
    for e in "${SUBSTRATE_COMMANDS[@]}"; do
        name=$(registry_name "$e"); words=$(registry_words "$e")
        [ -n "$words" ] || continue
        for w in $words; do
            printf "complete -c substrate -f -n '__fish_seen_subcommand_from %s' -a '%s' -d '%s'\n" "$name" "$(sq_escape "$w")" "$(sq_escape "$(flag_doc "$name" "$w")")"
        done
    done
}

completion_install() {
    local shell="$1" rc_file line tmp open_n close_n
    case "$shell" in
        bash) rc_file="$HOME/.bashrc"; line='source <(substrate completion bash)' ;;
        zsh)  rc_file="$HOME/.zshrc";  line='source <(substrate completion zsh)' ;;
        fish) rc_file="$HOME/.config/fish/completions/substrate.fish"; line='substrate completion fish | source' ;;
    esac
    mkdir -p "$(dirname "$rc_file")" || die "cannot create $(dirname "$rc_file")"
    touch "$rc_file" || die "cannot write $rc_file"
    open_n=$(grep -c '^# >>> substrate completion >>>$' "$rc_file" || true)
    close_n=$(grep -c '^# <<< substrate completion <<<$' "$rc_file" || true)
    if [ "$open_n" != "$close_n" ]; then
        die "unbalanced substrate completion markers in $rc_file ($open_n >>> vs $close_n <<<) — fix by hand, refusing to rewrite"
    fi
    tmp=$(mktemp) || die "mktemp failed"
    awk '
        $0 == "# >>> substrate completion >>>" { skip=1; next }
        $0 == "# <<< substrate completion <<<" { skip=0; next }
        !skip { print }
    ' "$rc_file" > "$tmp" || { rm -f "$tmp"; die "failed to read $rc_file"; }
    {
        printf '\n# >>> substrate completion >>>\n'
        printf '%s\n' "$line"
        printf '# <<< substrate completion <<<\n'
    } >> "$tmp"
    # Write back in place: keeps a symlinked rc file a symlink and preserves its mode.
    cat "$tmp" > "$rc_file" || { rm -f "$tmp"; die "failed to install completion into $rc_file"; }
    rm -f "$tmp"
    success "installed $shell completion into $rc_file — restart your shell or source $rc_file"
}

cmd_completion() {
    local shell="${1:-}"
    [ -n "$shell" ] || usage_cmd completion
    case "$shell" in
        bash|fish|zsh) ;;
        *) usage_cmd completion ;;
    esac
    shift
    local install=0 arg
    for arg in "$@"; do
        case "$arg" in
            --install) install=1 ;;
            *) usage_cmd completion ;;
        esac
    done
    if [ "$install" -eq 1 ]; then
        completion_install "$shell"
    else
        case "$shell" in
            bash) completion_bash ;;
            fish) completion_fish ;;
            zsh)  completion_zsh ;;
        esac
    fi
}
