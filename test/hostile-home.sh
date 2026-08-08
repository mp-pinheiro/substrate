#!/usr/bin/env bash
# Determinism oracle: poisoned user-config layers try to disable each
# detector's rule; the strict matrix must still reject every bad fixture.
# HOME itself is never overridden — pip-user toolchains resolve modules
# through it, so a fake HOME would break the tools instead of testing config
# isolation. The layers a gate run can genuinely leak through:
#   - XDG_CONFIG_HOME (ruff user config, shellcheck xdg rc)
#   - the scratch repo's parent directory (upward config walks) via TMPDIR
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export SUBSTRATE_ENGINE=bash

EVIL=$(mktemp -d)
trap 'rm -rf "$EVIL"' EXIT

mkdir -p "$EVIL/.config/ruff" "$EVIL/tmp"

# XDG layer: neuter the exact rules the bad fixtures trip.
printf '[lint]\nselect = []\n' > "$EVIL/.config/ruff/ruff.toml"
printf 'disable=all\n' > "$EVIL/.config/shellcheckrc"

# Scratch-repo parent: upward walks from the fixture repos land here first.
printf 'disable=all\n' > "$EVIL/tmp/.shellcheckrc"
printf '[lint]\nselect = []\n' > "$EVIL/tmp/ruff.toml"
printf '[tool.ruff.lint]\nselect = []\n' > "$EVIL/tmp/pyproject.toml"
printf '[sqlfluff]\nexclude_rules = CP01\n' > "$EVIL/tmp/.sqlfluff"
printf 'BasedOnStyle: WebKit\nIndentWidth: 3\n' > "$EVIL/tmp/.clang-format"
printf 'std = "max"\nignore = {".*"}\n' > "$EVIL/tmp/.luacheckrc"

# Git-config: CI runners have no ~/.gitconfig (defaultBranch=master); dev
# machines do. Poison GIT_CONFIG_GLOBAL so the matrix exercises the CI path.
printf '[init]\n\tdefaultBranch = master\n' > "$EVIL/gitconfig"

profiles=("$@")
[ ${#profiles[@]} -gt 0 ] || mapfile -t profiles < <(basename -a "$KIT_ROOT"/profiles/*/)

printf '[hostile-home] poisoned XDG + scratch parent at %s — strict matrix must stay green\n' "$EVIL"
export XDG_CONFIG_HOME="$EVIL/.config"
export TMPDIR="$EVIL/tmp"
export GIT_CONFIG_GLOBAL="$EVIL/gitconfig"
export CI=1
"$KIT_ROOT/test/matrix.sh" "${profiles[@]}"
