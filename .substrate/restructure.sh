#!/usr/bin/env bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
exec "${SUBSTRATE_ENGINE_BIN:-$ROOT/build/substrate-engine}" restructure "$@"
