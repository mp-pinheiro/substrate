#!/usr/bin/env bash
# Maintenance cadence: substrate-report.md must exist and be younger than
# report.max_age_days (0 opts out) — the queue recurs locally with no cron
# and no network. CI skips: the report is a local artifact and a wall-clock
# gate would fail builds on a timer; CI has its own scheduled report workflow.
set -uo pipefail
# shellcheck source=../gate-lib.sh
source "$SUBSTRATE_DIR/gate-lib.sh"

[ -n "${CI:-}" ] && exit 0

max_age=$(cfg '.report.max_age_days')
[ -n "$max_age" ] || max_age=14
case "$max_age" in
    *[!0-9]*) die_infra "report.max_age_days must be a non-negative integer (got: $max_age)" ;;
esac
[ "$max_age" -eq 0 ] && exit 0

REPORT="$REPO_ROOT/substrate-report.md"
if [ ! -f "$REPORT" ]; then
    printf 'no maintenance report — run: substrate report --write\n'
    exit 1
fi
first=$(head -n1 "$REPORT")
case "$first" in
    'generated: '*) gen="${first#generated: }" ;;
    *)
        printf 'substrate-report.md has no "generated:" first line — run: substrate report --write\n'
        exit 1
        ;;
esac
if ! gen_epoch=$(date -d "$gen" +%s 2>/dev/null); then
    printf 'substrate-report.md has an unparseable timestamp (%s) — run: substrate report --write\n' "$gen"
    exit 1
fi
now_epoch=$(date -u +%s)
age_days=$(((now_epoch - gen_epoch) / 86400))
if [ "$age_days" -gt "$max_age" ]; then
    printf 'maintenance report is %d days old (max %d) — run: substrate report --write, or set report.max_age_days: 0 in substrate.json\n' "$age_days" "$max_age"
    exit 1
fi
exit 0
