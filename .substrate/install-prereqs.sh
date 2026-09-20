#!/usr/bin/env bash
set -euo pipefail

[ "$(id -u)" -eq 0 ] || exit 0

git_version=2.47.3
git_sha256=c073471530e92b716641ea2b381fcd0ece53eea9a76a9c5415f93f89e870dd5f
git_archive="/tmp/git-${git_version}.tar.gz"
git_source="/tmp/git-${git_version}"

git_recent() {
    git version 2>/dev/null | grep -Eq 'git version 2\.(4[1-9]|[5-9][0-9])|git version [3-9]\.'
}

apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    sudo jq unzip file locales curl ca-certificates openssl git

if ! git_recent; then
    apt-get install -y -qq --no-install-recommends \
        build-essential autoconf libcurl4-openssl-dev libexpat1-dev libssl-dev zlib1g-dev gettext
    curl -sSfL -o "$git_archive" "https://www.kernel.org/pub/software/scm/git/git-${git_version}.tar.gz"
    printf '%s  %s\n' "$git_sha256" "$git_archive" | sha256sum -c -
    rm -rf "$git_source"
    mkdir -p "$git_source"
    tar -xzf "$git_archive" -C "$git_source" --strip-components=1
    make -C "$git_source" configure
    (cd "$git_source" && ./configure --prefix=/usr/local --without-tcltk)
    make -C "$git_source" -j"$(nproc)"
    make -C "$git_source" install
    hash -r
fi

localedef -i en_US -f UTF-8 en_US.UTF-8

git version | grep -Eq 'git version 2\.(4[1-9]|[5-9][0-9])|git version [3-9]\.' || {
    echo "::error::Git >= 2.41 is required by the pinned Jujutsu"
    exit 1
}
