#!/usr/bin/env bash
# Maintenance queue (advisory — never fails): duplication clusters, dead-code
# candidates, ratchet-tightening targets. Scheduled in CI (issue upsert) so the
# cadence recurs instead of depending on someone remembering to run it.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 0

report_duplication() {
    printf '\n-- duplication clusters (jscpd --min-tokens 35, worst 10 by lines)\n'
    if ! command -v bunx >/dev/null 2>&1; then
        printf 'skipped: bunx not found (install bun: https://bun.sh)\n'
        return 0
    fi
    local dir
    dir=$(mktemp -d)
    bunx --yes jscpd --min-tokens 35 --reporters json --output "$dir" --silent \
        --ignore "**/.git/**,**/.jj/**,**/.substrate/**,**/node_modules/**" . >/dev/null 2>&1
    if ! jq -e . "$dir/jscpd-report.json" >/dev/null 2>&1; then
        printf 'skipped: jscpd produced no report\n'
        rm -rf "$dir"
        return 0
    fi
    jq -r '"total duplication: \(.statistics.total.percentage // 0)% across \(.statistics.total.clones // 0) clones",
        (.duplicates | sort_by(-.lines) | .[0:10][]
         | "\(.firstFile.name):\(.firstFile.start)-\(.firstFile.end) <-> \(.secondFile.name):\(.secondFile.start)-\(.secondFile.end) — \(.lines) duplicated lines — extract the shared shape")' \
        "$dir/jscpd-report.json"
    rm -rf "$dir"
}

report_dead_code() {
    printf '\n-- dead code candidates\n'
    local pyfiles=() f
    while IFS= read -r f; do
        [ -n "$f" ] && pyfiles+=("$f")
    done < <(git ls-files '*.py' 2>/dev/null)
    if [ ${#pyfiles[@]} -eq 0 ]; then
        printf 'no python files tracked\n'
    elif command -v vulture >/dev/null 2>&1; then
        vulture ${pyfiles[@]+"${pyfiles[@]}"} || true
    else
        printf 'skipped: vulture not found (pipx install vulture) — %s python files unscanned\n' "${#pyfiles[@]}"
    fi
    if [ -f package.json ]; then
        printf 'candidate: knip for dead exports (package.json present; knip is repo-config-dependent, report-only by design)\n'
    fi
}

report_ratchet() {
    printf '\n-- ratchet tightening candidates (baseline metrics, desc)\n'
    if ! jq -e . substrate-baseline.json >/dev/null 2>&1; then
        printf 'skipped: no substrate-baseline.json (run the gate, then --update-baseline)\n'
        return 0
    fi
    jq -r '.metrics | to_entries | sort_by(-.value)[] | "\(.key) = \(.value)"' substrate-baseline.json
    printf 'run the gate: improved metrics print a lock-in hint; tighten with --update-baseline\n'
}

printf '== substrate report: maintenance queue (advisory — never fails)\n'
report_duplication
report_dead_code
report_ratchet
exit 0
