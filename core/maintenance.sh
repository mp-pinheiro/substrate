#!/usr/bin/env bash
maintenance_run() {
    local dir root
    dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    root="$(cd "$dir/.." && pwd)"
    exec "${SUBSTRATE_ENGINE_BIN:-$root/build/substrate-engine}" maintenance "$@"
}
