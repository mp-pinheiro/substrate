#!/usr/bin/env bash
# Maintenance queue (advisory — never fails): duplication clusters, dead-code
# candidates, ratchet-tightening targets. --write drops substrate-report.md
# (55-report-freshness keeps it fresh offline); CI upserts the issue extra.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 0

report_duplication() {
    printf '## Duplicate code\n\n'
    printf 'Known generated copies, fixtures, templates, and documentation are excluded.\n\n'
    local JSCPD=()
    if command -v jscpd >/dev/null 2>&1; then
        JSCPD=(jscpd)
    elif command -v bunx >/dev/null 2>&1; then
        JSCPD=(bunx --yes jscpd@5.0.14)
    else
        printf "Status: not scanned. Install \`jscpd\` with \`bun install -g jscpd@5.0.14\`.\n"
        return 0
    fi
    local dir percentage clones shown
    dir=$(mktemp -d)
    "${JSCPD[@]}" --min-tokens 35 --reporters json --output "$dir" --silent \
        --ignore "**/.git/**,**/.jj/**,**/.substrate/**,**/.omp/**,**/.claude/**,**/.github/**,**/node_modules/**,**/fixtures/**,**/templates/**,**/*.md" . >/dev/null 2>&1
    if ! jq -e . "$dir/jscpd-report.json" >/dev/null 2>&1; then
        printf "Status: not scanned because \`jscpd\` produced no report.\n"
        rm -rf "$dir"
        return 0
    fi
    percentage=$(jq -r '(((.statistics.total.percentage // 0) * 100 | round) / 100)' "$dir/jscpd-report.json")
    clones=$(jq -r '.statistics.total.clones // 0' "$dir/jscpd-report.json")
    shown=$(jq -r '[(.duplicates // [])[]] | length | if . > 10 then 10 else . end' "$dir/jscpd-report.json")
    printf 'Summary: %s%% duplicated code across %s clusters. Showing the %s largest.\n\n' "$percentage" "$clones" "$shown"
    if jq -e '(.duplicates // []) | length > 0' "$dir/jscpd-report.json" >/dev/null; then
        printf '| Lines | First range | Second range |\n'
        printf '| ---: | --- | --- |\n'
        jq -r '(.duplicates | sort_by(-.lines) | .[0:10][]
            | "| \(.lines) | `\(.firstFile.name):\(.firstFile.start)-\(.firstFile.end)` | `\(.secondFile.name):\(.secondFile.start)-\(.secondFile.end)` |")' \
            "$dir/jscpd-report.json"
    else
        printf 'No duplicate clusters found.\n'
    fi
    rm -rf "$dir"
}

report_dead_code() {
    printf '\n## Possible dead code\n\n'
    printf 'Static analysis can misidentify dynamic or indirectly used code. Confirm each result before deleting anything.\n\n'
    local pyfiles=() vulture_cmd=() f output finding
    while IFS= read -r f; do
        [ -n "$f" ] && pyfiles+=("$f")
    done < <(git ls-files '*.py' ':!**/fixtures/**' ':!.substrate/**' 2>/dev/null)
    if command -v vulture >/dev/null 2>&1; then
        vulture_cmd=(vulture)
    elif [ -n "${CI:-}" ] && command -v pipx >/dev/null 2>&1; then
        vulture_cmd=(pipx run --quiet vulture)
    fi
    if [ ${#pyfiles[@]} -eq 0 ]; then
        printf 'No tracked Python files.\n'
    elif [ ${#vulture_cmd[@]} -gt 0 ]; then
        output=$("${vulture_cmd[@]}" ${pyfiles[@]+"${pyfiles[@]}"} 2>&1 || true)
        if [ -z "$output" ]; then
            printf 'No Python candidates found.\n'
        else
            while IFS= read -r finding; do
                [ -n "$finding" ] && printf -- "- \`%s\`\n" "$finding"
            done <<< "$output"
        fi
    else
        if [ ${#pyfiles[@]} -eq 1 ]; then
            printf "Status: not scanned. \`vulture\` is missing, so 1 Python file was skipped.\n"
        else
            printf "Status: not scanned. \`vulture\` is missing, so %s Python files were skipped.\n" "${#pyfiles[@]}"
        fi
    fi
    if [ -f package.json ]; then
        printf '\nJavaScript and TypeScript dead exports were not scanned. Knip needs repository-specific configuration.\n'
    fi
}

report_ratchet() {
    printf '\n## Baseline limits\n\n'
    printf 'These values are quality ceilings, not failures. Lower them only when the gate reports an improvement.\n\n'
    if ! jq -e . substrate-baseline.json >/dev/null 2>&1; then
        printf "Status: no baseline. Run the gate, then save it with \`substrate gate --update-baseline\`.\n"
        return 0
    fi
    printf '| Metric | Current limit |\n'
    printf '| --- | ---: |\n'
    jq -r '.metrics | to_entries | sort_by(-.value)[] | "| `\(.key)` | \(.value) |"' substrate-baseline.json
    printf "\nWhen the gate reports an improvement, save the tighter limits with \`substrate gate --update-baseline\`.\n"
}

run_report() {
    local generated="${1:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
    printf '# Substrate maintenance report\n\n'
    printf "Generated: \`%s\`\n\n" "$generated"
    printf 'The scheduled workflow refreshes this report every day. This is a cleanup list, not a CI failure.\n\n'
    printf 'Start with the largest duplicate blocks. Treat dead-code entries as leads, and verify them before changing code.\n\n'
    report_duplication
    report_dead_code
    report_ratchet
}

case "${1:-}" in
    --write)
        generated=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        { printf 'generated: %s\n\n' "$generated"; run_report "$generated"; } > "$REPO_ROOT/substrate-report.md"
        printf 'report written: %s\n' "$REPO_ROOT/substrate-report.md"
        ;;
    '') run_report ;;
    *) printf 'usage: report.sh [--write]\n' >&2; exit 2 ;;
esac
exit 0
