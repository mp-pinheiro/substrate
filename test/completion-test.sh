#!/usr/bin/env bash
# Completion guard: SUBSTRATE_COMMANDS in core/completion.sh (sourced by
# bin/substrate) is the single source of truth for usage and `substrate
# completion`. This suite fails when the dispatch case or any cmd_* handler
# references a command or flag missing from the registry, when a flag parsed by
# the Go maintenance parser (internal/maintenance/args.go) is not offered for
# the maintenance commands, when a registry word lacks a SUBSTRATE_FLAG_DOCS
# entry, on unescaped apostrophes, on wrong synopsis rendering, and on
# completion --install clobbering symlinks or markers. It also checks the
# emitted bash/fish/zsh scripts.
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SUBSTRATE_NO_USER_HARNESS=1
export SUBSTRATE_ENGINE_BIN="${SUBSTRATE_ENGINE_BIN:-$KIT_ROOT/build/substrate-engine}"
BIN="$KIT_ROOT/bin/substrate"
COMPLETION_LIB="$KIT_ROOT/core/completion.sh"

fail() { printf 'completion-test FAIL: %s\n' "$1" >&2; exit 1; }

[ -x "$BIN" ] || fail "bin/substrate not executable"
[ -f "$COMPLETION_LIB" ] || fail "core/completion.sh missing"
bash -n "$BIN" || fail "bin/substrate has a syntax error"
bash -n "$COMPLETION_LIB" || fail "core/completion.sh has a syntax error"

REG_ENTRIES=()
while IFS= read -r line; do
    REG_ENTRIES+=("$line")
done < <(awk '/^SUBSTRATE_COMMANDS=\(/,/^\)/' "$COMPLETION_LIB" | grep -oE '"[^"]+"' | tr -d '"')
[ "${#REG_ENTRIES[@]}" -gt 0 ] || fail "SUBSTRATE_COMMANDS registry not found in core/completion.sh"

reg_names=()
reg_words=" "
for e in "${REG_ENTRIES[@]}"; do
    name=${e%%|*}; rest=${e#*|}; words=${rest#*|}
    [ -n "$name" ] || fail "registry entry without a name: $e"
    case "$e" in *"'"*) fail "registry entry contains an apostrophe: $e" ;; esac
    reg_names+=("$name")
    reg_words="$reg_words$words "
done

cmd_words() { # words of one command in the registry
    local e name
    for e in "${REG_ENTRIES[@]}"; do
        name=${e%%|*}
        if [ "$name" = "$1" ]; then printf '%s ' "${e#*|*|}"; return; fi
    done
}

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

# The pre-dispatch --help handler must be registry-driven, not a third copy of
# the command list: no command labels may appear outside the dispatch case.
if awk '/^case "\$\{1:-\}" in/,/^esac$/' "$BIN" | grep -qE '^    (bootstrap|init|gate|version|checkpoint|restructure|baseline|doctor|verify|update|engine|selftest|audit|report|completion)\|'; then
    fail "bin/substrate still hardcodes the command list outside the dispatch case"
fi

SCAN_FLAGS=$(
    {
        awk '/^case "\$\{1:-\}" in/,/^esac$/' "$BIN"
        awk '/^cmd_[a-z_]+\(\) \{/,/^\}$/' "$BIN" "$COMPLETION_LIB"
    } | grep -oE '\--[a-z][a-z-]*' | sort -u
)
while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$reg_words" in
        *" $f "*) ;;
        *) fail "flag $f is used in the dispatch/cmd_* but missing from SUBSTRATE_COMMANDS" ;;
    esac
done <<< "$SCAN_FLAGS"

# The Go maintenance parser accepts flags the shell never sees; the registry
# must offer them for the maintenance commands or completion/--help lie.
GO_FLAGS=$(grep -oE '"--[a-z-]+=?"' "$KIT_ROOT/internal/maintenance/args.go" | tr -d '"' | sort -u)
[ -n "$GO_FLAGS" ] || fail "no flags parsed from internal/maintenance/args.go — scan drifted?"
while IFS= read -r f; do
    [ -n "$f" ] || continue
    # A bare flag that args.go only rejects in favor of the keyed form is not accepted.
    case "$f" in *=) ;; *) case "$GO_FLAGS" in *"$f="*) continue ;; esac ;; esac
    for c in bootstrap init; do
        [ "$f" = "--apply" ] && continue
        case " $(cmd_words "$c")" in
            *" $f "*) ;;
            *) fail "Go maintenance flag $f accepted for $c but missing from its registry words" ;;
        esac
    done
    case "$f" in
        --apply|--profile|--vcs) continue ;;
    esac
    case " $(cmd_words update)" in
        *" $f "*) ;;
        *) fail "Go maintenance flag $f accepted for update but missing from its registry words" ;;
    esac
done <<< "$GO_FLAGS"

FLAG_DOC_KEYS=()
while IFS= read -r line; do
    FLAG_DOC_KEYS+=("${line%%|*}|$(printf '%s' "${line#*|}" | cut -d'|' -f1)")
done < <(awk '/^SUBSTRATE_FLAG_DOCS=\(/,/^\)/' "$COMPLETION_LIB" | grep -oE '"[^"]+"' | tr -d '"')
for e in "${REG_ENTRIES[@]}"; do
    name=${e%%|*}; rest=${e#*|}; words=${rest#*|}
    for w in $words; do
        found=0
        for k in "${FLAG_DOC_KEYS[@]}"; do
            [ "$k" = "$name|$w" ] && { found=1; break; }
        done
        [ "$found" -eq 1 ] || fail "no SUBSTRATE_FLAG_DOCS entry for '$name|$w'"
    done
done
for k in "${FLAG_DOC_KEYS[@]}"; do
    found=0
    for e in "${REG_ENTRIES[@]}"; do
        name=${e%%|*}; rest=${e#*|}; words=${rest#*|}
        for w in $words; do
            [ "$k" = "$name|$w" ] && { found=1; break; }
        done
    done
    [ "$found" -eq 1 ] || fail "orphan SUBSTRATE_FLAG_DOCS entry '$k' (no such registry word)"
done

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
    case "$sh" in
        fish) grep -Fq 'comma-separated profiles' "$out" \
            || fail "fish completion script missing flag descriptions from SUBSTRATE_FLAG_DOCS" ;;
        zsh)
            grep -Fq 'comma-separated profiles' "$out" \
                || fail "zsh completion script missing flag descriptions from SUBSTRATE_FLAG_DOCS"
            grep -Fq 'compdef _substrate substrate' "$out" \
                || fail "zsh completion script missing compdef registration"
            ;;
    esac
done

env -u CI "$BIN" > "$T/usage.out" 2>&1
grep -Fq 'Commands:' "$T/usage.out" || fail "usage should have a Commands: section"
for name in "${reg_names[@]}"; do
    grep -Eq "^  $name( +|\$)" "$T/usage.out" || fail "usage missing command '$name'"
done
grep -Fq -- '--profile' "$T/usage.out" && fail "root usage should not list per-command flags"
for name in "${reg_names[@]}"; do
    if ! env -u CI "$BIN" "$name" --help > "$T/help.out" 2>&1; then
        fail "$name --help should exit 0"
    fi
    grep -Fq "usage: substrate $name" "$T/help.out" || fail "$name --help missing synopsis"
    grep -Fq '[--help]' "$T/help.out" && fail "$name --help should not appear in the synopsis"
done
if ! env -u CI "$BIN" gate --deep --help > "$T/deep-help.out" 2>&1; then
    fail "gate --deep --help should exit 0"
fi
grep -Fq 'usage: substrate gate' "$T/deep-help.out" || fail "gate --deep --help missing gate synopsis"
env -u CI "$BIN" init --help > "$T/init-help.out" 2>&1
grep -Fq 'Flags:' "$T/init-help.out" || fail "init --help missing Flags: section"
# Required flags and value placeholders must survive in the synopsis.
grep -Fq 'usage: substrate init --profile <a,b> [--vcs <auto,git,jj>' "$T/init-help.out" \
    || fail "init --help synopsis missing required --profile <a,b> / [--vcs ...]: $(head -1 "$T/init-help.out")"
grep -Fq '[--profile' "$T/init-help.out" && fail "required --profile must not render inside optional brackets"
grep -Fq -- '--profile <a,b>' "$T/init-help.out" || fail "init --help Flags table missing '--profile <a,b>'"
env -u CI "$BIN" checkpoint --help > "$T/cp-help.out" 2>&1
grep -Fq 'usage: substrate checkpoint --message <message> [' "$T/cp-help.out" \
    || fail "checkpoint --help synopsis missing required --message <message>: $(head -1 "$T/cp-help.out")"
grep -Fq -- '--accept-regression=<metric>[,<metric>]' "$T/cp-help.out" \
    || fail "checkpoint --help missing keyed --accept-regression=<metric>[,<metric>]"
for w in $reg_words; do
    case "$w" in --profile|--vcs|--force|--from-worktree) ;;
        *) continue ;;
    esac
    grep -Fq -- "$w" "$T/init-help.out" || fail "init --help missing word '$w'"
done
grep -Fq 'comma-separated profiles' "$T/init-help.out" || fail "init --help missing flag descriptions"

# init without --profile: fresh repo must fail in Go, initialized repo must rerun clean.
REPO="$T/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.name substrate
git -C "$REPO" config user.email substrate@localhost
(cd "$REPO" && env -u CI "$BIN" init > "$T/init-fresh.out" 2>&1)
rc=$?
[ "$rc" -ne 0 ] || fail "init without --profile in a fresh repo should fail"
grep -Fq 'requires --profile' "$T/init-fresh.out" || fail "fresh init should report 'requires --profile'"
(cd "$REPO" && env -u CI "$BIN" init --profile shell >/dev/null 2>&1) || fail "init --profile shell failed"
(cd "$REPO" && env -u CI "$BIN" init > "$T/init-rerun.out" 2>&1) \
    || fail "rerunning init without --profile in an initialized repo must exit 0: $(cat "$T/init-rerun.out")"

env -u CI "$BIN" completion powershell >"$T/bad.out" 2>&1
[ $? -eq 2 ] || fail "completion with unknown shell should exit 2"
grep -Fq 'usage:' "$T/bad.out" || fail "completion with unknown shell should print usage"

env -u CI "$BIN" > "$T/noargs.out" 2>&1
[ $? -eq 2 ] || fail "bare substrate should exit 2"
grep -Fq 'usage:' "$T/noargs.out" || fail "bare substrate should print usage"

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
# bash install must preserve the symlink and the target's mode, and be idempotent.
[ -L "$HOME/.bashrc" ] || fail ".bashrc symlink was replaced by a regular file"
[ "$(stat -L -f '%Lp' "$HOME/.bashrc" 2>/dev/null || stat -L -c '%a' "$HOME/.bashrc")" = "640" ] \
    || fail ".bashrc target mode changed during install"
[ "$(grep -c 'source <(substrate completion bash)' "$HOME/.bashrc")" = 1 ] || fail "bash one-liner duplicated or missing in .bashrc"
[ "$(grep -c '^# >>> substrate completion >>>$' "$HOME/.bashrc")" = 1 ] || fail "bash marker duplicated in .bashrc"
[ "$(grep -c '^# <<< substrate completion <<<$' "$HOME/.bashrc")" = 1 ] || fail "bash end marker duplicated in .bashrc"
grep -Fq 'alias ll="ls -l"' "$HOME/.bashrc" || fail "install ate existing .bashrc content"
bash -n "$HOME/.bashrc" || fail ".bashrc invalid after install"
# zsh same contract.
[ "$(grep -c 'source <(substrate completion zsh)' "$HOME/.zshrc")" = 1 ] || fail "zsh one-liner duplicated or missing in .zshrc"
[ "$(grep -c '^# >>> substrate completion >>>$' "$HOME/.zshrc")" = 1 ] || fail "zsh marker duplicated in .zshrc"
bash -n "$HOME/.zshrc" || fail ".zshrc invalid after install"
# fish installs into the autoloaded completions dir, not config.fish.
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
