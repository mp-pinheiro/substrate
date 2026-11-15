#!/usr/bin/env bash
# Completion guard: SUBSTRATE_COMMANDS in bin/substrate is the single source of
# truth for usage and `substrate completion`. This suite fails when the
# dispatch case or any cmd_* handler references a command or flag missing
# from the registry, and checks the emitted bash/fish/zsh scripts.
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SUBSTRATE_NO_USER_HARNESS=1
BIN="$KIT_ROOT/bin/substrate"

fail() { printf 'completion-test FAIL: %s\n' "$1" >&2; exit 1; }

[ -x "$BIN" ] || fail "bin/substrate not executable"
bash -n "$BIN" || fail "bin/substrate has a syntax error"

# --- parse the registry -----------------------------------------------------
REG_ENTRIES=()
while IFS= read -r line; do
    REG_ENTRIES+=("$line")
done < <(awk '/^SUBSTRATE_COMMANDS=\(/,/^\)/' "$BIN" | grep -oE '"[^"]+"' | tr -d '"')
[ "${#REG_ENTRIES[@]}" -gt 0 ] || fail "SUBSTRATE_COMMANDS registry not found in bin/substrate"

reg_names=()
reg_words=" "
for e in "${REG_ENTRIES[@]}"; do
    name=${e%%|*}; rest=${e#*|}; words=${rest#*|}
    [ -n "$name" ] || fail "registry entry without a name: $e"
    case "$e" in *"'"*) fail "registry entry contains an apostrophe: $e" ;; esac
    reg_names+=("$name")
    reg_words="$reg_words$words "
done

# --- command parity: dispatch case labels == registry names -----------------
CASE_LABELS=()
while IFS= read -r line; do
    CASE_LABELS+=("$line")
done < <(awk '/^case "\$\{1:-\}" in/,/^esac$/' "$BIN" | grep -oE '^    [a-z]+[)]' | tr -d ' )')
[ "${#CASE_LABELS[@]}" -gt 0 ] || fail "could not extract dispatch case labels"

REG_SORTED=$(printf '%s\n' "${reg_names[@]}" | sort)
CASE_SORTED=$(printf '%s\n' "${CASE_LABELS[@]}" | sort)
[ "$(printf '%s\n' "${reg_names[@]}" | wc -l)" -eq "$(printf '%s\n' "${CASE_LABELS[@]}" | wc -l)" ] \
    || fail "registry has $(printf '%s\n' "${reg_names[@]}" | wc -l) commands but dispatch has $(printf '%s\n' "${CASE_LABELS[@]}" | wc -l)"
[ "$REG_SORTED" = "$CASE_SORTED" ] \
    || fail "dispatch case labels differ from SUBSTRATE_COMMANDS (add the command to both): $(diff <(printf '%s\n' "$REG_SORTED") <(printf '%s\n' "$CASE_SORTED") | tr '\n' ' ')"

# --- flag parity: every --flag used in dispatch/cmd_* is declared -----------
SCAN_FLAGS=$(
    {
        awk '/^case "\$\{1:-\}" in/,/^esac$/' "$BIN"
        awk '/^cmd_[a-z_]+\(\) \{/,/^\}$/' "$BIN"
    } | grep -oE '\--[a-z][a-z-]*' | sort -u
)
while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$reg_words" in
        *" $f "*) ;;
        *) fail "flag $f is used in the dispatch/cmd_* but missing from SUBSTRATE_COMMANDS" ;;
    esac
done <<< "$SCAN_FLAGS"

# --- emitted scripts ---------------------------------------------------------
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

for sh in bash fish zsh; do
    out="$T/$sh.comp"
    env -u CI "$BIN" completion "$sh" > "$out" 2>"$T/$sh.err" \
        || fail "completion $sh exited non-zero: $(cat "$T/$sh.err")"
    [ -s "$out" ] || fail "completion $sh emitted an empty script"
    case "$sh" in
        bash) bash -n "$out" || fail "emitted bash script fails bash -n" ;;
        zsh)  command -v zsh >/dev/null 2>&1 && { zsh -n "$out" || fail "emitted zsh script fails zsh -n"; } ;;
        fish) command -v fish >/dev/null 2>&1 && { fish -n "$out" || fail "emitted fish script fails fish -n"; } ;;
    esac
    for name in "${reg_names[@]}"; do
        grep -Fq -- "$name" "$out" || fail "command '$name' missing from $sh completion script"
    done
    for w in $reg_words; do
        grep -Fq -- "$w" "$out" || fail "word '$w' missing from $sh completion script"
    done
done

# --- bad input ---------------------------------------------------------------
env -u CI "$BIN" completion powershell >"$T/bad.out" 2>&1
[ $? -eq 2 ] || fail "completion with unknown shell should exit 2"
grep -Fq 'usage:' "$T/bad.out" || fail "completion with unknown shell should print usage"

env -u CI "$BIN" >"$T/noargs.out" 2>&1
[ $? -eq 2 ] || fail "bare substrate should exit 2"
grep -Fq 'usage:' "$T/noargs.out" || fail "bare substrate should print usage"

# --- install mode is a symlink-safe, idempotent one-liner --------------------
export HOME="$T/home"
mkdir -p "$HOME" "$T/dotfiles"
printf 'alias ll="ls -l"\n' > "$T/dotfiles/bashrc"
chmod 640 "$T/dotfiles/bashrc"
ln -s "$T/dotfiles/bashrc" "$HOME/.bashrc"
printf 'alias ll="ls -l"\n' > "$HOME/.zshrc"
for sh in bash zsh fish; do
    env -u CI "$BIN" completion "$sh" --install >/dev/null || fail "completion $sh --install failed"
    env -u CI "$BIN" completion "$sh" --install >/dev/null || fail "completion $sh --install (2nd run) failed"
done
[ -L "$HOME/.bashrc" ] || fail ".bashrc symlink was replaced by a regular file"
[ "$(stat -L -f '%Lp' "$HOME/.bashrc" 2>/dev/null || stat -L -c '%a' "$HOME/.bashrc")" = "640" ] \
    || fail ".bashrc target mode changed during install"
[ "$(grep -c 'source <(substrate completion bash)' "$HOME/.bashrc")" = 1 ] || fail "bash one-liner duplicated or missing in .bashrc"
[ "$(grep -c '^# >>> substrate completion >>>$' "$HOME/.bashrc")" = 1 ] || fail "bash marker duplicated in .bashrc"
[ "$(grep -c '^# <<< substrate completion <<<$' "$HOME/.bashrc")" = 1 ] || fail "bash end marker duplicated in .bashrc"
grep -Fq 'alias ll="ls -l"' "$HOME/.bashrc" || fail "install ate existing .bashrc content"
bash -n "$HOME/.bashrc" || fail ".bashrc invalid after install"
[ "$(grep -c 'source <(substrate completion zsh)' "$HOME/.zshrc")" = 1 ] || fail "zsh one-liner duplicated or missing in .zshrc"
[ "$(grep -c '^# >>> substrate completion >>>$' "$HOME/.zshrc")" = 1 ] || fail "zsh marker duplicated in .zshrc"
[ -f "$HOME/.config/fish/completions/substrate.fish" ] || fail "fish completion file not created"
[ ! -e "$HOME/.config/fish/config.fish" ] || fail "fish install should not touch config.fish"
[ "$(grep -c '^substrate completion fish | source$' "$HOME/.config/fish/completions/substrate.fish")" = 1 ] || fail "fish one-liner duplicated or missing"
[ "$(grep -c '^# >>> substrate completion >>>$' "$HOME/.config/fish/completions/substrate.fish")" = 1 ] || fail "fish marker duplicated"
# An orphan >>> marker must abort without rewriting the rc file.
printf '# >>> substrate completion >>>\nhand-edited tail\n' > "$HOME/.zshrc"
env -u CI "$BIN" completion zsh --install >/dev/null 2>&1
[ $? -ne 0 ] || fail "install with unbalanced markers should fail"
[ "$(cat "$HOME/.zshrc")" = '# >>> substrate completion >>>
hand-edited tail' ] || fail "unbalanced-marker install rewrote the rc file"

printf 'completion-test OK (%s commands)\n' "${#reg_names[@]}"
