#!/usr/bin/env bash
# Lints claimed shell files: executables (own shebang) get the full shellcheck
# treatment; sourced fragments run as bash with the cross-file noise excluded.
# zsh files have no shellcheck support — `zsh -n` syntax-checks them instead.
set -uo pipefail
# shellcheck source=../gate-lib.sh
source "$SUBSTRATE_DIR/gate-lib.sh"

executables=()
fragments=()
zsh_files=()
while IFS= read -r f; do
    entry=$(lang_entry "$f")
    [ -n "$entry" ] || continue
    [ "$(jq -r '.profile' <<< "$entry")" = "shell" ] || continue
    if [ "$(jq -r '.ast_lang // empty' <<< "$entry")" = "bash" ]; then
        if head -c2 "$f" 2>/dev/null | grep -q '#!'; then
            executables+=("$f")
        else
            fragments+=("$f")
        fi
    else
        zsh_files+=("$f")
    fi
done < "$INVENTORY"

rc=0

if [ ${#executables[@]} -gt 0 ] || [ ${#fragments[@]} -gt 0 ]; then
    if require_bin_ci shellcheck "profile toolchain — see profiles/shell/profile.json"; then
        if [ ${#executables[@]} -gt 0 ]; then
            shellcheck -S warning -x -e SC1091 "${executables[@]}" || rc=1
        fi
        if [ ${#fragments[@]} -gt 0 ]; then
            shellcheck -S warning -s bash -e SC1091,SC2154 "${fragments[@]}" || rc=1
        fi
    fi
fi

if [ ${#zsh_files[@]} -gt 0 ]; then
    if have zsh; then
        for f in "${zsh_files[@]}"; do
            zsh -n "$f" 2>&1 || { printf 'zsh syntax: %s failed\n' "$f"; rc=1; }
        done
    else
        warn "zsh not installed — zsh syntax check skipped"
    fi
fi

exit "$rc"
