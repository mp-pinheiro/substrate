#!/usr/bin/env bash
set -euo pipefail

# Single supported target today; gitleaks ships linux_x64 release tarballs.
arch=$(uname -m)
file_arch=x86-64
case "$(uname -s):$arch" in
    Linux:x86_64) ;;
    *) printf 'install-gitleaks: unsupported platform: %s:%s\n' "$(uname -s)" "$arch" >&2; exit 1 ;;
esac

if ! command -v file >/dev/null 2>&1; then
    printf 'install-gitleaks: "file" is required to verify the binary architecture\n' >&2
    exit 1
fi

version=8.30.1
sha256=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
archive="$tmp/gitleaks.tar.gz"
url="https://github.com/gitleaks/gitleaks/releases/download/v${version}/gitleaks_${version}_linux_x64.tar.gz"

curl -sSfL -o "$archive" "$url"
printf '%s  %s\n' "$sha256" "$archive" | sha256sum -c -
tar -xzf "$archive" -C "$tmp" gitleaks

# Reject a wrong-architecture payload before it overwrites a working install.
case "$(file -b "$tmp/gitleaks")" in
    *"$file_arch"*) ;;
    *) printf 'install-gitleaks: downloaded binary is wrong architecture; expected %s\n' "$file_arch" >&2; exit 1 ;;
esac

dest=${GITLEAKS_INSTALL_DIR:-/usr/local/bin}
dest_bin="$dest/gitleaks"

# Warn if a gitleaks that resolves earlier on PATH would shadow this install.
shadow=$(command -v gitleaks 2>/dev/null || true)
if [ -n "$shadow" ] && [ "$(readlink -f "$shadow" 2>/dev/null || printf '%s' "$shadow")" != "$(readlink -f "$dest_bin" 2>/dev/null || printf '%s' "$dest_bin")" ]; then
    printf 'install-gitleaks: WARNING: %s precedes %s on PATH and will shadow the new install.\n' "$shadow" "$dest" >&2
    printf 'install-gitleaks: remove the stale binary, or: GITLEAKS_INSTALL_DIR=%s %s\n' "$(dirname "$shadow")" "$0" >&2
fi

if [ -w "$dest" ]; then
    install -m 0755 "$tmp/gitleaks" "$dest_bin"
elif command -v sudo >/dev/null 2>&1; then
    sudo install -m 0755 "$tmp/gitleaks" "$dest_bin"
else
    printf 'install-gitleaks: %s is not writable and sudo is unavailable\n' "$dest" >&2
    exit 1
fi

# The binary that actually resolves on PATH must be the host architecture.
# A stale wrong-arch binary in an earlier PATH entry would otherwise silently win.
resolved=$(command -v gitleaks || true)
if [ -n "$resolved" ]; then
    case "$(file -b "$resolved")" in
        *"$file_arch"*) printf 'install-gitleaks: %s (%s)\n' "$resolved" "$file_arch" ;;
        *) printf 'install-gitleaks: %s resolves to the wrong architecture (stale shadow); remove it and rerun.\n' "$resolved" >&2; exit 1 ;;
    esac
fi
