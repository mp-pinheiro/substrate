#!/usr/bin/env bash
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$KIT_ROOT/substrate.json"

[ -f "$CONFIG" ] || { printf 'dev-toolchain: substrate.json missing — run: substrate init\n' >&2; exit 2; }

missing=0
checked=0

extract_version() {
    local cmd="$1"
    sed -nE 's/.*\b(v?[0-9]+\.[0-9]+\.[0-9]+[0-9a-zA-Z._-]*).*/\1/p' <<< "$cmd" | tail -1
}

bin_version() {
    local bin="$1"
    case "$bin" in
        go)           command "$bin" version 2>/dev/null | sed -nE 's/.*go([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' ;;
        golangci-lint) command "$bin" --version 2>/dev/null | sed -nE 's/.*version ([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' ;;
        shellcheck)   command "$bin" --version 2>/dev/null | sed -nE 's/version: ([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' ;;
        ruff)         command "$bin" --version 2>/dev/null | sed -nE 's/ruff ([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' ;;
        vulture)      command "$bin" --version 2>/dev/null | sed -nE 's/vulture ([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' ;;
        python3)      command "$bin" --version 2>/dev/null | sed -nE 's/Python ([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' ;;
        actionlint)   command "$bin" -version 2>/dev/null | sed -nE 's/^([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' ;;
        *)            command "$bin" --version 2>/dev/null | head -1 ;;
    esac
}

dev_install_cmd() {
    local bin="$1" ci_version="$2"
    case "$bin" in
        go)
            printf '  go install golang.org/dl/go%s@latest && go%s download\n' "$ci_version" "$ci_version" ;;
        golangci-lint)
            printf '  go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v%s\n' "${ci_version#v}" ;;
        shellcheck|zsh|python3|python3-pip|pipx)
            printf '  sudo apt-get install -y %s\n' "$bin" ;;
        ruff|vulture|import-linter|lint-imports)
            printf '  pipx install %s\n' "$bin" ;;
        actionlint)
            printf '  curl -sSfL -o /tmp/actionlint.tar.gz https://github.com/rhysd/actionlint/releases/download/v%s/actionlint_%s_linux_$([ "$(uname -m)" = aarch64 ] && echo arm64 || echo amd64).tar.gz && sudo tar -xzf /tmp/actionlint.tar.gz -C /usr/local/bin actionlint\n' "$ci_version" "$ci_version" ;;
        *)
            printf '  # no dev install recipe for %s — see CI profile\n' "$bin" ;;
    esac
}

while IFS= read -r profile; do
    [ -n "$profile" ] || continue
    for dir in "$KIT_ROOT/substrate-profiles/$profile" "$KIT_ROOT/profiles/$profile"; do
        pjson="$dir/profile.json"
        [ -f "$pjson" ] || continue

        while IFS= read -r bin; do
            [ -n "$bin" ] || continue
            checked=$((checked + 1))
            if command -v "$bin" >/dev/null 2>&1; then
                installed_ver=$(bin_version "$bin")
                printf '[ok] %s' "$bin"
                [ -n "$installed_ver" ] && printf ' (%s)' "$installed_ver"
                printf '\n'
            else
                missing=$((missing + 1))
                printf '[!!] %-20s — missing' "$bin"
                ci_version=""
                while IFS= read -r ci_line; do
                    ci_version=$(extract_version "$ci_line")
                    [ -z "$ci_version" ] || break
                done < <(jq -r '(.ci // [])[]' "$pjson" 2>/dev/null)
                if [ -n "$ci_version" ]; then
                    printf ' (CI pins %s)' "$ci_version"
                fi
                printf '\n'
                dev_install_cmd "$bin" "${ci_version:-latest}" 2>/dev/null
            fi
        done < <(jq -r '(.toolchain // [])[].bin' "$pjson" 2>/dev/null)
        break
    done
done < <(jq -r '.profiles[]' "$CONFIG" 2>/dev/null)

printf '\ndev-toolchain: %d checked, %d missing\n' "$checked" "$missing"
[ "$missing" -eq 0 ] || exit 1
