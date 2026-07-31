#!/usr/bin/env bash
# Enforces canonical `terraform fmt` formatting on claimed terraform files.
set -uo pipefail
# shellcheck source=../gate-lib.sh
source "$SUBSTRATE_DIR/gate-lib.sh"

[ -n "$(profile_files terraform)" ] || exit 0

require_bin_ci terraform "profile toolchain — see profiles/terraform/profile.json" || exit 0

out=$(terraform fmt -check -recursive -diff 2>&1)
rc=$?
case "$rc" in
    0) exit 0 ;;
    3)
        printf '%s\n' "$out"
        printf 'terraform fmt — files above are not canonically formatted — run: terraform fmt -recursive\n'
        exit 1
        ;;
    *) die_infra "terraform fmt failed (rc=$rc): $out" ;;
esac
