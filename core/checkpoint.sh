#!/usr/bin/env bash
set -uo pipefail
exec substrate-engine checkpoint "$@"