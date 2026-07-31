#!/usr/bin/env bash
# Gate runner. Vendored at <repo>/.substrate/gate.sh; discovers checks in
# .substrate/checks.d, runs them under the check contract (docs/contracts.md),
# ratchets emitted metrics against substrate-baseline.json.
# Usage: gate.sh [--update-baseline] [--accept-regression]
set -uo pipefail

SUBSTRATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SUBSTRATE_DIR/.." && pwd)"
cd "$REPO_ROOT" || exit 2
export SUBSTRATE_DIR REPO_ROOT
export CONFIG="$REPO_ROOT/substrate.json"
export LANGMAP="$SUBSTRATE_DIR/langmap.json"
export BASELINE="$REPO_ROOT/substrate-baseline.json"

# shellcheck source=gate-lib.sh
source "$SUBSTRATE_DIR/gate-lib.sh"

UPDATE_BASELINE=0
ACCEPT_REGRESSION=0
for arg in "$@"; do
    case "$arg" in
        --update-baseline) UPDATE_BASELINE=1 ;;
        --accept-regression) UPDATE_BASELINE=1; ACCEPT_REGRESSION=1 ;;
        *) printf 'usage: %s [--update-baseline] [--accept-regression]\n' "$0" >&2; exit 2 ;;
    esac
done

jq -e . "$CONFIG" >/dev/null 2>&1 || { warn "substrate.json missing or corrupt — run: substrate init"; exit 2; }
jq -e . "$LANGMAP" >/dev/null 2>&1 || { warn "$LANGMAP missing or corrupt — run: substrate init (or update)"; exit 2; }
if [ -f "$BASELINE" ] && ! jq -e . "$BASELINE" >/dev/null 2>&1; then
    warn "$BASELINE is corrupt — restore it from VCS or delete it and rerun --update-baseline"
    exit 2
fi

INVENTORY=$(mktemp)
METRICS=$(mktemp)
export INVENTORY METRICS
cleanup() { rm -f "$INVENTORY" "$METRICS"; }
trap cleanup EXIT

build_inventory() {
    if [ -n "${SUBSTRATE_FILE_LIST:-}" ]; then
        cp "$SUBSTRATE_FILE_LIST" "$INVENTORY"
        return 0
    fi
    local mode listing
    mode=$(cfg '.inventory')
    if [ "$mode" = "auto" ] || [ -z "$mode" ]; then
        if [ -d .jj ]; then mode=jj; else mode=git; fi
    fi
    case "$mode" in
        jj)  listing=$(jj file list) || die_infra "jj file list failed" ;;
        git) listing=$(git ls-files) || die_infra "git ls-files failed" ;;
        *) die_infra "unknown inventory mode: $mode" ;;
    esac
    local f
    while IFS= read -r f; do
        [ -f "$f" ] && printf '%s\n' "$f"
    done <<< "$listing" > "$INVENTORY"
    [ -s "$INVENTORY" ] || die_infra "inventory is empty — wrong directory, or VCS not initialized"
}

FAILURES=0
run_checks() {
    local disabled chk name out rc
    disabled=$(cfg_json '.checks.disabled // []')
    for chk in "$SUBSTRATE_DIR"/checks.d/*.sh; do
        [ -f "$chk" ] || continue
        name=$(basename "$chk")
        if jq -e --arg n "$name" 'index($n) != null' <<< "$disabled" >/dev/null; then
            warn "$name: disabled in substrate.json"
            continue
        fi
        out=$(bash "$chk" 2>&1)
        rc=$?
        if [ "$rc" -eq 0 ]; then
            [ -n "$out" ] && printf '%s\n' "$out"
            success "$name"
        elif [ "$rc" -eq 1 ]; then
            printf '%s\n' "$out"
            warn "FAIL $name"
            FAILURES=$((FAILURES + 1))
        else
            printf '%s\n' "$out"
            warn "FAIL $name: infrastructure failure (rc=$rc) — the gate cannot pass blind"
            FAILURES=$((FAILURES + 1))
        fi
    done
}

CURRENT_METRICS='{}'
ratchet() {
    CURRENT_METRICS=$(jq -sc 'map({(.name): .value}) | add // {}' "$METRICS") \
        || { warn "metrics aggregation failed"; FAILURES=$((FAILURES + 1)); return 1; }

    if [ ! -f "$BASELINE" ]; then
        local total
        total=$(jq -r 'length' <<< "$CURRENT_METRICS")
        warn "ratchet: no baseline yet ($total metric(s) pending) — run --update-baseline on a green run to grandfather current debt"
        return 0
    fi

    local base worse better
    base=$(jq -c '.metrics // {}' "$BASELINE") || { warn "ratchet: cannot read baseline metrics"; FAILURES=$((FAILURES + 1)); return 1; }

    if ! worse=$(jq -rn --argjson c "$CURRENT_METRICS" --argjson b "$base" \
        '$c | to_entries[] | select(.value > (($b[.key]) // 0) + 1e-9) | "\(.key): \(.value) (baseline \($b[.key] // 0))"'); then
        warn "ratchet: baseline comparison failed"
        FAILURES=$((FAILURES + 1))
        return 1
    fi
    if ! better=$(jq -rn --argjson c "$CURRENT_METRICS" --argjson b "$base" \
        '[$b | to_entries[] | select((($c[.key]) // 0) < .value - 1e-9) | .key] | length'); then
        warn "ratchet: baseline comparison failed"
        FAILURES=$((FAILURES + 1))
        return 1
    fi

    if [ -n "$worse" ]; then
        printf '%s\n' "$worse"
        warn "FAIL ratchet: metrics above their grandfathered baseline (new debt is rejected)"
        FAILURES=$((FAILURES + 1))
    elif [ "$better" -gt 0 ]; then
        info "ratchet: $better metric(s) improved on baseline — run --update-baseline to lock in"
    else
        success "ratchet: all metrics at or below baseline"
    fi
}

write_baseline() {
    if [ "$FAILURES" -gt 0 ] && [ "$ACCEPT_REGRESSION" -ne 1 ]; then
        warn "refusing to update baseline with $FAILURES failing check(s) — fix them, or pass --accept-regression to loosen deliberately"
        return 1
    fi
    local new_baseline
    if ! new_baseline=$(jq -n --argjson m "$CURRENT_METRICS" '{metrics: ($m | to_entries | sort_by(.key) | from_entries)}'); then
        warn "baseline: serialization failed — not writing"
        return 1
    fi
    if [ "$ACCEPT_REGRESSION" -eq 1 ] && [ -f "$BASELINE" ]; then
        warn "accepting regressions — baseline diff:"
        diff <(jq -S . "$BASELINE") <(jq -S . <<< "$new_baseline") || true
    fi
    printf '%s\n' "$new_baseline" > "$BASELINE"
    success "baseline written to $BASELINE"
}

info "substrate gate: $REPO_ROOT"
build_inventory
run_checks
ratchet

if [ "$UPDATE_BASELINE" -eq 1 ]; then
    write_baseline
fi

if [ "$FAILURES" -gt 0 ]; then
    warn "gate: $FAILURES check(s) failed"
    exit 1
fi
success "gate: all checks passed"
