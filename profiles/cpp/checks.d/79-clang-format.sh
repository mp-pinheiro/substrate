#!/usr/bin/env bash
# Enforces the repo's .clang-format on claimed C/C++ files; without a repo
# config the check is inactive rather than guessing a style.
set -uo pipefail
# shellcheck source=../gate-lib.sh
source "$SUBSTRATE_DIR/gate-lib.sh"

if [ ! -f "$REPO_ROOT/.clang-format" ]; then
    warn "no .clang-format at repo root — formatting check inactive"
    exit 0
fi

files=()
mapfile -t files < <(profile_files cpp cpp)

[ ${#files[@]} -gt 0 ] || exit 0

require_bin_ci clang-format "profile toolchain — see profiles/cpp/profile.json" || exit 0

out=$(clang-format --dry-run -Werror -style="file:$REPO_ROOT/.clang-format" "${files[@]}" 2>&1)
rc=$?
[ "$rc" -eq 0 ] && exit 0
printf '%s\n' "$out"
exit 1
