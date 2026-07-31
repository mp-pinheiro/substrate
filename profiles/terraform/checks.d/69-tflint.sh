#!/usr/bin/env bash
# Lints terraform files with tflint (bundled terraform ruleset, recommended
# preset via .tflint.hcl — no plugin init or network required).
set -uo pipefail
# shellcheck source=../gate-lib.sh
source "$SUBSTRATE_DIR/gate-lib.sh"

[ -n "$(profile_files terraform)" ] || exit 0

if [ ! -f "$REPO_ROOT/.tflint.hcl" ]; then
    warn ".tflint.hcl absent — tflint inactive (substrate init installs a template)"
    exit 0
fi

require_bin_ci tflint "profile toolchain — see profiles/terraform/profile.json" || exit 0

out=$(tflint --recursive --no-color --config "$REPO_ROOT/.tflint.hcl" 2>&1)
rc=$?
case "$rc" in
    0) exit 0 ;;
    2)
        printf '%s\n' "$out"
        printf 'tflint — fix the findings above or disable the rule in .tflint.hcl\n'
        exit 1
        ;;
    *) die_infra "tflint failed (rc=$rc): $out" ;;
esac
