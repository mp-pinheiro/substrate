#!/usr/bin/env bash
set -euo pipefail

case "$(uname -s):$(uname -m)" in
    Linux:x86_64) ;;
    *) printf 'install-gitleaks: unsupported platform: %s:%s\n' "$(uname -s)" "$(uname -m)" >&2; exit 1 ;;
esac

version=8.30.1
sha256=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
archive="$tmp/gitleaks.tar.gz"
url="https://github.com/gitleaks/gitleaks/releases/download/v${version}/gitleaks_${version}_linux_x64.tar.gz"

curl -sSfL -o "$archive" "$url"
printf '%s  %s\n' "$sha256" "$archive" | sha256sum -c -
tar -xzf "$archive" -C "$tmp" gitleaks

dest=${GITLEAKS_INSTALL_DIR:-/usr/local/bin}
if [ -w "$dest" ]; then
    install -m 0755 "$tmp/gitleaks" "$dest/gitleaks"
elif command -v sudo >/dev/null 2>&1; then
    sudo install -m 0755 "$tmp/gitleaks" "$dest/gitleaks"
else
    printf 'install-gitleaks: %s is not writable and sudo is unavailable\n' "$dest" >&2
    exit 1
fi
