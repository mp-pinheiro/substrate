#!/usr/bin/env bash
# Secrets in git history. Local: loud skip when gitleaks is missing (CI runs
# gitleaks-action as its own workflow step). A repo with no .git cannot be
# scanned at all — that is fatal, not silent: colocate or disable explicitly.
set -uo pipefail
# shellcheck source=../gate-lib.sh
source "$SUBSTRATE_DIR/gate-lib.sh"

if [ ! -d .git ]; then
    die_infra "no .git directory — colocate (jj git init --colocate) or disable 50-gitleaks.sh explicitly in substrate.json checks.disabled"
fi
have gitleaks || { warn "gitleaks not installed — skipped (CI runs gitleaks-action)"; exit 0; }

if gitleaks detect --no-banner --redact >/dev/null 2>&1; then
    exit 0
fi
printf 'potential secrets in git history — run: gitleaks detect --no-banner\n'
exit 1
