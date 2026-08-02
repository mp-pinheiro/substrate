#!/usr/bin/env bash
# Secrets in the current working state and every unpublished Git/JJ commit.
# Full reachable-history ownership belongs to the cached CI deep scan.
set -uo pipefail
# shellcheck source=../gate-lib.sh
source "$SUBSTRATE_DIR/gate-lib.sh"
# shellcheck source=../gitleaks-lib.sh
source "$SUBSTRATE_DIR/gitleaks-lib.sh"

inside=$(git rev-parse --is-inside-work-tree 2>/dev/null) \
    || die_infra "no Git worktree - colocate (jj git init --colocate) or disable 50-gitleaks.sh explicitly in substrate.json checks.disabled"
[ "$inside" = true ] \
    || die_infra "no Git worktree - colocate (jj git init --colocate) or disable 50-gitleaks.sh explicitly in substrate.json checks.disabled"
have gitleaks || { warn "gitleaks not installed — skipped (CI owns the deep scan)"; exit 0; }

log_opts=$(pending_gitleaks_log_opts) \
    || die_infra "cannot construct the pending Git/JJ scan range"
report=$(mktemp)
trap 'rm -f "$report"' EXIT
gitleaks git --no-banner --redact --verbose --log-opts="$log_opts" >"$report" 2>&1
rc=$?
case "$rc" in
    0) exit 0 ;;
    1)
        cat "$report"
        printf 'potential secrets in pending work — inspect the finding above; deep history remains CI-owned\n'
        exit 1 ;;
    *)
        cat "$report" >&2
        die_infra "gitleaks pending scan failed (rc=$rc)" ;;
esac
