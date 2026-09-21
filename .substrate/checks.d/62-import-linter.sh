#!/usr/bin/env bash
source "$SUBSTRATE_DIR/import-linter-check.sh" || { printf 'import-linter implementation missing\n' >&2; exit 3; }
