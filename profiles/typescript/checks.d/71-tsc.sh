#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=../gate-lib.sh
source "$SUBSTRATE_DIR/gate-lib.sh"

if [ ! -f tsconfig.json ]; then
    warn "no tsconfig.json — tsc check inactive (substrate init installs a template)"
    exit 0
fi

override=$(cfg_check .command)
if [ -n "$override" ]; then
    errf=$(mktemp)
    out=$(eval "$override" 2>"$errf")
    rc=$?
    err=$(cat "$errf")
    rm -f "$errf"
    [ "$rc" -eq 0 ] && exit 0
    printf '%s\n' "$out"
    if grep -q 'error TS' <<< "$out"; then
        exit 1
    fi
    die_infra "configured tsc command failed (rc=$rc) — ${err:-no stderr output}"
fi

require_bin_ci bun "profile toolchain — https://bun.sh" || exit 0

errf=$(mktemp)
out=$(bunx --yes -p typescript@6.0.3 tsc --noEmit 2>"$errf")
rc=$?
err=$(cat "$errf")
rm -f "$errf"

[ "$rc" -eq 0 ] && exit 0

if grep -q 'error TS' <<< "$out"; then
    printf '%s\n' "$out"
    exit 1
fi
die_infra "tsc via bunx failed without diagnostics (rc=$rc) — ${err:-no stderr output}"
