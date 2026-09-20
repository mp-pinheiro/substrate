#!/usr/bin/env bash
set -euo pipefail

git_version=2.47.3
git_sha256=c073471530e92b716641ea2b381fcd0ece53eea9a76a9c5415f93f89e870dd5f
git_archive="/tmp/git-${git_version}.tar.gz"
git_source="/tmp/git-${git_version}"

git_recent() {
    git version 2>/dev/null | grep -Eq 'git version 2\.(4[1-9]|[5-9][0-9])|git version [3-9]\.'
}

if git_recent; then
    printf 'install-git: %s already satisfies the Jujutsu requirement\n' "$(git version)"
    exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
    printf 'install-git: %s is older than 2.41 and this process is not root\n' "$(git version 2>/dev/null || echo 'no git')" >&2
    exit 1
fi

apt-get update -qq
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

git_recent || {
    echo "::error::Git >= 2.41 is required by the pinned Jujutsu"
    exit 1
}
