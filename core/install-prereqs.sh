#!/usr/bin/env bash
set -euo pipefail

[ "$(id -u)" -eq 0 ] || exit 0

apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    sudo jq unzip file locales curl ca-certificates openssl git

localedef -i en_US -f UTF-8 en_US.UTF-8
