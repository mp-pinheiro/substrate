#!/usr/bin/env bash
# Maintenance queue (advisory — never fails): duplication clusters, dead-code
# candidates, and ratchet-tightening targets. --refresh atomically maintains
# ignored local state when due; CI upserts the durable issue.
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
    printf 'These values are quality ceilings, not failures. Successful agent checkpoints lower improved ceilings automatically.\n\n'
    if ! jq -e . substrate-baseline.json >/dev/null 2>&1; then
        printf "Status: no baseline. Run the gate, then save it with \`substrate gate --update-baseline\`.\n"
        return 0
    fi
    printf '| Metric | Current limit |\n'
    printf '| --- | ---: |\n'
    jq -r '.metrics | to_entries | sort_by(-.value)[] | "| `\(.key)` | \(.value) |"' substrate-baseline.json
    printf "\nAgent checkpoints save tighter limits automatically. Use \`substrate baseline\` only to adopt initial debt or perform explicit maintenance.\n"
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

REPORT="$REPO_ROOT/substrate-report.md"
report_warn() {
    printf 'report advisory: %s\n' "$*" >&2
}
report_is_tracked() {
    git ls-files --error-unmatch -- substrate-report.md >/dev/null 2>&1
}
ensure_report_ignored() {
    local git_dir exclude
    git_dir=$(git rev-parse --git-common-dir 2>/dev/null) || return 0
    case "$git_dir" in
        /*) ;;
        *) git_dir="$REPO_ROOT/$git_dir" ;;
    esac
    exclude="$git_dir/info/exclude"
    mkdir -p "$(dirname "$exclude")" || return 1
    if [ ! -f "$exclude" ] || ! grep -Fqx '/substrate-report.md' "$exclude"; then
        printf '\n# substrate advisory state\n/substrate-report.md\n' >> "$exclude" || return 1
    fi
}
write_report() {
    local generated staged
    [ ! -L "$REPORT" ] || { report_warn "$REPORT is a symlink — not writing"; return 1; }
    generated=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    staged=$(mktemp "$REPORT.XXXXXX") || { report_warn "cannot stage $REPORT"; return 1; }
    if { printf 'generated: %s\n\n' "$generated"; run_report "$generated"; } > "$staged" \
        && mv -f "$staged" "$REPORT"; then
        printf 'report written: %s\n' "$REPORT"
        return 0
    fi
    rm -f "$staged"
    report_warn "generation failed — existing report preserved"
    return 1
}
report_due() {
    local max_age first generated_epoch now_epoch age_days
    max_age=$(jq -r '.report.max_age_days // 14' substrate.json 2>/dev/null)
    case "$max_age" in
        ''|*[!0-9]*) report_warn "invalid report.max_age_days; using 14"; max_age=14 ;;
    esac
    [ "$max_age" -ne 0 ] || return 1
    [ -f "$REPORT" ] || return 0
    IFS= read -r first < "$REPORT" || return 0
    case "$first" in
        'generated: '*) ;;
        *) return 0 ;;
    esac
    generated_epoch=$(date -d "${first#generated: }" +%s 2>/dev/null) || return 0
    now_epoch=$(date -u +%s)
    [ "$generated_epoch" -le "$now_epoch" ] || return 0
    age_days=$(((now_epoch - generated_epoch) / 86400))
    [ "$age_days" -ge "$max_age" ]
}

case "${1:-}" in
    --write)
        ensure_report_ignored || report_warn "cannot register local ignore"
        write_report || true
        ;;
    --refresh)
        if report_is_tracked; then
            report_warn "$REPORT is tracked — automatic refresh skipped; untrack it to keep advisory state local"
        else
            ensure_report_ignored || report_warn "cannot register local ignore"
            if report_due; then
                write_report || true
            else
                printf 'report current: %s\n' "$REPORT"
            fi
        fi
        ;;
    '') run_report ;;
    *) printf 'usage: report.sh [--write|--refresh]\n' >&2; exit 2 ;;
esac
exit 0
