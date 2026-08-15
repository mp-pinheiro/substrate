#!/usr/bin/env bash
set -euo pipefail

case "$(uname -s):$(uname -m)" in
    Linux:x86_64)
        jj_arch=x86_64-unknown-linux-musl
        sha256=59e5588583ac82b623239929368c65b90735931c0f26b5a16c1f04d5bb97643d
        ;;
    Linux:aarch64)
        jj_arch=aarch64-unknown-linux-musl
        sha256=289197b6bec60b4e57d47260624b617716f737eb02cdfd9155791b2576aa5862
        ;;
    *) printf 'install-jj: unsupported platform: %s:%s\n' "$(uname -s)" "$(uname -m)" >&2; exit 1 ;;
esac

version=0.43.0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
archive="$tmp/jj.tar.gz"
url="https://github.com/jj-vcs/jj/releases/download/v${version}/jj-v${version}-${jj_arch}.tar.gz"

curl -sSfL -o "$archive" "$url"
printf '%s  %s\n' "$sha256" "$archive" | sha256sum -c -
tar -xzf "$archive" -C "$tmp" ./jj

dest=${JJ_INSTALL_DIR:-/usr/local/bin}
if [ -w "$dest" ]; then
    install -m 0755 "$tmp/jj" "$dest/jj"
elif command -v sudo >/dev/null 2>&1; then
    sudo install -m 0755 "$tmp/jj" "$dest/jj"
else
    printf 'install-jj: %s is not writable and sudo is unavailable\n' "$dest" >&2
    exit 1
fi
