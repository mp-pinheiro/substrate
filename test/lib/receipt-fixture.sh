# Repo fixture shared by the receipt dual-leg oracles: a minimal substrate
# repo whose claimed inventory and hashed inputs are byte-fixed, so bash and
# go legs compute the same fingerprint. Sourced only.

seed_repo() {
    local repo="$1"
    mkdir -p "$repo/.substrate/checks.d"
    cd "$repo" || exit 9
    git init -q --initial-branch=main
    git config user.name substrate
    git config user.email substrate@localhost
    printf '{"version":1,"profiles":[],"inventory":"git","unscanned":["*.txt"],"protected_paths":[],"comment":{"allow_tags":[]},"budgets":{"max_file_lines":500},"duplication":{"min_tokens":35},"report":{"max_age_days":14},"checks":{"disabled":[]},"contracts":[]}\n' > substrate.json
    printf '{"metrics":{}}\n' > substrate-baseline.json
    printf '0.1.0\n' > .substrate/VERSION
    printf '#!/usr/bin/env bash\nexit 0\n' > .substrate/checks.d/probe.sh
    chmod +x .substrate/checks.d/probe.sh
    printf 'tracked\n' > tracked.txt
    printf '{"scripts":{"verify":"true"}}\n' > package.json
    printf 'lock-v1\n' > bun.lock
    git add -A
    git commit -qm 'chore: initialize'
}
