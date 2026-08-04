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
    if ! find . -maxdepth 3 -type d -name node_modules 2>/dev/null | grep -q .; then
        warn "node_modules absent — tsc override skipped locally, CI runs it"
        exit 0
    fi
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
    if [ -n "${CI:-}" ]; then
        die_infra "configured tsc command failed (rc=$rc) — ${err:-no stderr output}"
    fi
    warn "configured tsc command failed (rc=$rc) — check skipped locally, CI runs it — ${err:-no stderr output}"
    exit 0
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
