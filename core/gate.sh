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
ACCEPT_KEYS=""
TIGHTEN_BASELINE=0
for arg in "$@"; do
    case "$arg" in
        --update-baseline) UPDATE_BASELINE=1 ;;
        --tighten) UPDATE_BASELINE=1; TIGHTEN_BASELINE=1 ;;
        --accept-regression) UPDATE_BASELINE=1; ACCEPT_REGRESSION=1 ;;
        --accept-regression=*) UPDATE_BASELINE=1; ACCEPT_REGRESSION=1; ACCEPT_KEYS="${arg#--accept-regression=}" ;;
        *) printf 'usage: %s [--update-baseline|--tighten|--accept-regression[=key1,key2]]\n' "$0" >&2; exit 2 ;;
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
CLAIMS=$(mktemp)
export INVENTORY METRICS CLAIMS
cleanup() { rm -f "$INVENTORY" "$METRICS" "$CLAIMS" "$CLAIMS.raw"; }
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

# Resolve every inventory claim once; checks read the exported CLAIMS table
# instead of spawning jq per file per check.
build_claims() {
    local f ext entry interp row match ejson
    local -A ext_map=()
    while IFS=$'\t' read -r ext entry; do
        ext_map[$ext]=$entry
    done < <(jq -r 'to_entries[] | select(.key != "__shebang__") | [.key, (.value | tojson)] | join("\t")' "$LANGMAP")
    local shebang_rows=()
    mapfile -t shebang_rows < <(
        jq -r '(.__shebang__ // [])[] | [(.match | join(" ")), (.entry | tojson)] | join("\t")' "$LANGMAP")
    local scopes_active=0
    jq -e '.scopes // empty | length > 0' "$CONFIG" >/dev/null 2>&1 && scopes_active=1
    while IFS= read -r f; do
        ext=".${f##*.}"
        entry=${ext_map[$ext]:-}
        if [ -z "$entry" ] && [ -f "$f" ]; then
            interp=$(shebang_interp "$f")
            if [ -n "$interp" ]; then
                for row in ${shebang_rows[@]+"${shebang_rows[@]}"}; do
                    match=${row%%$'\t'*}
                    ejson=${row#*$'\t'}
                    case " $match " in
                        *" $interp "*) entry=$ejson; break ;;
                    esac
                done
            fi
        fi
        [ -n "$entry" ] || continue
        if [ "$scopes_active" -eq 1 ] && ! scope_allows "$f" "$(jq -r '.profile' <<< "$entry")"; then
            continue
        fi
        printf '%s\t%s\n' "$f" "$entry"
    done < "$INVENTORY" > "$CLAIMS.raw"
    # \u001f keeps empty columns intact: tab is IFS whitespace and would
    # collapse the ast_lang gap in line/exempt-mode rows on read.
    jq -R -r 'split("\t") as [$p, $e] | ($e | fromjson) as $j
        | [$p, ($j.profile // ""), ($j.ast_lang // ""), ($j.mode // ""), $e] | join("\u001f")' \
        "$CLAIMS.raw" > "$CLAIMS" || die_infra "claims table build failed"
    rm -f "$CLAIMS.raw"
    # Capture sink for byte-comparing runner implementations; the rename
    # publishes the finished table so no reader can see it half-written.
    if [ -n "${SUBSTRATE_CLAIMS_OUT:-}" ]; then
        local staged mode
        staged=$(mktemp "$SUBSTRATE_CLAIMS_OUT.XXXXXX") \
            || die_infra "claims capture: cannot stage next to $SUBSTRATE_CLAIMS_OUT"
        mode=$(printf '%04o' "$((0666 & ~0$(umask)))")
        if ! cp "$CLAIMS" "$staged" || ! chmod "$mode" "$staged" \
            || ! mv -f "$staged" "$SUBSTRATE_CLAIMS_OUT"; then
            rm -f "$staged"
            die_infra "claims capture: cannot write $SUBSTRATE_CLAIMS_OUT"
        fi
    fi
}

FAILURES=0
format_duration() {
    local ms="$1"
    if [ "$ms" -ge 1000 ]; then
        printf '%d.%01ds' $((ms / 1000)) $((ms % 1000 / 100))
    else
        printf '%dms' "$ms"
    fi
}
RUN_DIR=""
RUN_NAMES=()
RUN_PIDS=()
report_check() {
    local idx="$1" name rc ms out took
    name=${RUN_NAMES[idx]}
    wait "${RUN_PIDS[idx]}"
    read -r rc ms < "$RUN_DIR/$name.rc" || { rc=70; ms=0; }
    [ -f "$RUN_DIR/$name.metrics" ] && cat "$RUN_DIR/$name.metrics" >> "$METRICS"
    out=$(cat "$RUN_DIR/$name.out" 2>/dev/null)
    took=$(format_duration "$ms")
    if [ "$rc" -eq 0 ]; then
        [ -n "$out" ] && printf '%s\n' "$out"
        success "$name ($took)"
    elif [ "$rc" -eq 1 ]; then
        printf '%s\n' "$out"
        warn "FAIL $name ($took)"
        FAILURES=$((FAILURES + 1))
    else
        printf '%s\n' "$out"
        warn "FAIL $name: infrastructure failure (rc=$rc) — the gate cannot pass blind"
        FAILURES=$((FAILURES + 1))
    fi
}
# Checks are contract-isolated (own tmpdirs, per-check METRICS shard), so they
# run concurrently up to SUBSTRATE_GATE_JOBS; reporting stays in name order.
run_checks() {
    local disabled chk name max running=0 next=0 count=0
    disabled=$(cfg_json '.checks.disabled // []')
    RUN_DIR=$(mktemp -d)
    RUN_NAMES=()
    RUN_PIDS=()
    max=${SUBSTRATE_GATE_JOBS:-$(nproc 2>/dev/null || printf '4')}
    case "$max" in
        ''|*[!0-9]*) max=4 ;;
    esac
    [ "$max" -ge 1 ] || max=1
    for chk in "$SUBSTRATE_DIR"/checks.d/*.sh; do
        [ -f "$chk" ] || continue
        name=$(basename "$chk")
        if jq -e --arg n "$name" 'index($n) != null' <<< "$disabled" >/dev/null; then
            warn "$name: disabled in substrate.json"
            continue
        fi
        RUN_NAMES[count]=$name
        (
            export SUBSTRATE_CHECK_NAME="$name"
            export METRICS="$RUN_DIR/$name.metrics"
            : > "$METRICS"
            start=$(date +%s%N)
            out=$(bash "$chk" 2>&1)
            rc=$?
            end=$(date +%s%N)
            printf '%s\n' "$out" > "$RUN_DIR/$name.out"
            printf '%s %s\n' "$rc" "$(( (end - start) / 1000000 ))" > "$RUN_DIR/$name.rc"
        ) &
        RUN_PIDS[count]=$!
        count=$((count + 1))
        running=$((running + 1))
        if [ "$running" -ge "$max" ]; then
            report_check "$next"
            next=$((next + 1))
            running=$((running - 1))
        fi
    done
    while [ "$next" -lt "$count" ]; do
        report_check "$next"
        next=$((next + 1))
    done
    rm -rf "$RUN_DIR"
}

CURRENT_METRICS='{}'
CURRENT_DIR='{}'
ratchet() {
    CURRENT_METRICS=$(jq -sc 'map({(.name): .value}) | add // {}' "$METRICS") \
        || { warn "metrics aggregation failed"; FAILURES=$((FAILURES + 1)); return 1; }
    CURRENT_DIR=$(jq -sc '[.[] | select(.dir == "hi") | {(.name): "hi"}] | add // {}' "$METRICS") \
        || { warn "direction aggregation failed"; FAILURES=$((FAILURES + 1)); return 1; }

    if [ ! -f "$BASELINE" ]; then
        local total
        total=$(jq -r 'length' <<< "$CURRENT_METRICS")
        warn "ratchet: no baseline yet ($total metric(s) pending) — run --update-baseline on a green run to grandfather current debt"
        return 0
    fi

    local base base_dir worse better
    base=$(jq -c '.metrics // {}' "$BASELINE") || { warn "ratchet: cannot read baseline metrics"; FAILURES=$((FAILURES + 1)); return 1; }
    base_dir=$(jq -c '.direction // {}' "$BASELINE") || { warn "ratchet: cannot read baseline direction"; FAILURES=$((FAILURES + 1)); return 1; }

    if ! worse=$(jq -rn --argjson c "$CURRENT_METRICS" --argjson b "$base" --argjson d "$CURRENT_DIR" --argjson bd "$base_dir" \
        '$c | to_entries[] | select(if (($d[.key] // $bd[.key] // "lo")) == "hi" then .value < (($b[.key]) // 0) - 1e-9 else .value > (($b[.key]) // 0) + 1e-9 end) | "\(.key): \(.value) (baseline \($b[.key] // 0))"'); then
        warn "ratchet: baseline comparison failed"
        FAILURES=$((FAILURES + 1)); return 1
    fi
    if ! better=$(jq -rn --argjson c "$CURRENT_METRICS" --argjson b "$base" --argjson d "$CURRENT_DIR" --argjson bd "$base_dir" \
        '[$b | to_entries[] | select(if (($d[.key] // $bd[.key] // "lo")) == "hi" then (($c[.key]) // 0) > .value + 1e-9 else (($c[.key]) // 0) < .value - 1e-9 end) | .key] | length'); then
        warn "ratchet: baseline comparison failed"
        FAILURES=$((FAILURES + 1)); return 1
    fi

    if [ -n "$worse" ]; then
        if [ "$ACCEPT_REGRESSION" -eq 1 ] && [ -n "$ACCEPT_KEYS" ]; then
            local accepted="" rejected=""
            while IFS= read -r line; do
                [ -n "$line" ] || continue
                local key="${line%%:*}"
                case ",$ACCEPT_KEYS," in
                    *",$key,"*) accepted="${accepted:+$accepted$'\n'}$line" ;;
                    *) rejected="${rejected:+$rejected$'\n'}$line" ;;
                esac
            done <<< "$worse"
            if [ -n "$rejected" ]; then
                printf '%s\n' "$rejected"
                warn "FAIL ratchet: non-accepted metrics regressed"
                FAILURES=$((FAILURES + 1))
            fi
            if [ -n "$accepted" ]; then
                printf '%s\n' "$accepted"
                warn "ratchet: accepted regression(s) per --accept-regression=$ACCEPT_KEYS"
            fi
        elif [ "$ACCEPT_REGRESSION" -eq 1 ]; then
            printf '%s\n' "$worse"
            warn "ratchet: metrics regressed — explicit regression acceptance requested"
        else
            printf '%s\n' "$worse"
            warn "FAIL ratchet: metrics regressed beyond their grandfathered baseline"
            FAILURES=$((FAILURES + 1))
        fi
    elif [ "$better" -gt 0 ]; then
        info "ratchet: $better metric(s) improved on baseline — checkpoint locks them in automatically"
    else
        success "ratchet: all metrics at or better than baseline"
    fi
}

write_baseline() {
    if [ "$TIGHTEN_BASELINE" -eq 1 ] && [ ! -f "$BASELINE" ]; then
        warn "baseline absent — establish initial debt explicitly with: substrate baseline"
        return 1
    fi
    if [ "$FAILURES" -gt 0 ]; then
        warn "refusing to update baseline with $FAILURES failing check(s) — fix detector failures; use --accept-regression only for metric regressions"
        return 1
    fi
    local new_baseline staged
    if [ "$TIGHTEN_BASELINE" -eq 1 ] || { [ "$ACCEPT_REGRESSION" -eq 1 ] && [ -n "$ACCEPT_KEYS" ]; }; then
        new_baseline=$(jq -n --slurpfile old "$BASELINE" --argjson m "$CURRENT_METRICS" --argjson dir "$CURRENT_DIR" --arg keys "${ACCEPT_KEYS:-}" \
            '($old[0].metrics // {}) as $old_m | ($old[0].direction // {}) as $old_d
            | ($keys | split(",") | map(select(length > 0))) as $accepted
            | ($old_m | with_entries(select((.key | in($m) | not) and ($old_d[.key] == "hi")))) as $kept
            | {metrics: (reduce ($m | to_entries[]) as $e ($kept;
                if ($accepted | index($e.key)) then
                    .[$e.key] = $e.value
                elif (($dir[$e.key] // $old_d[$e.key] // "lo")) == "hi" then
                    .[$e.key] = ([$old_m[$e.key] // $e.value, $e.value] | max)
                else
                    .[$e.key] = ([$old_m[$e.key] // $e.value, $e.value] | min)
                end)
                | to_entries | sort_by(.key) | from_entries),
               direction: ($dir + ($old_d | with_entries(select(.key | in($kept)))))}') \
            || { warn "baseline: serialization failed — not writing"; return 1; }
    else
        new_baseline=$(jq -n --argjson m "$CURRENT_METRICS" --argjson dir "$CURRENT_DIR" \
            '{metrics: ($m | to_entries | sort_by(.key) | from_entries), direction: $dir}') \
            || { warn "baseline: serialization failed — not writing"; return 1; }
    fi
    if [ -f "$BASELINE" ]; then
        local pruned
        pruned=$(jq -rn --slurpfile old "$BASELINE" --argjson nb "$new_baseline" \
            '((($old[0].metrics // {}) | keys) - (($nb.metrics // {}) | keys)) | join(", ")') || pruned=""
        [ -z "$pruned" ] \
            || warn "baseline: pruning resolved ceiling(s): $pruned — a key vanishes when its debt is fixed OR its check stopped running; confirm the latter is intended"
    fi
    if [ "$ACCEPT_REGRESSION" -eq 1 ] && [ -f "$BASELINE" ]; then
        warn "accepting regressions — baseline diff:"
        diff <(jq -S . "$BASELINE") <(jq -S . <<< "$new_baseline") || true
    fi
    if ! staged=$(mktemp "$BASELINE.XXXXXX"); then
        warn "baseline: cannot stage next to $BASELINE — not writing"
        return 1
    fi
    if ! printf '%s\n' "$new_baseline" > "$staged"; then
        rm -f "$staged"
        warn "baseline: staging write failed — not writing"
        return 1
    fi
    [ ! -f "$BASELINE" ] || chmod --reference="$BASELINE" "$staged" 2>/dev/null
    if [ -f "$BASELINE" ] && cmp -s "$BASELINE" "$staged"; then
        rm -f "$staged"
        info "baseline already records the current metric floor"
        return 0
    fi
    if mv -f "$staged" "$BASELINE"; then
        success "baseline tightened at $BASELINE"
        return 0
    fi
    rm -f "$staged"
    warn "baseline: atomic replacement failed — original preserved"
    return 1
}

GATE_START=$(date +%s%N)
info "substrate gate: $REPO_ROOT"
build_inventory
build_claims
run_checks
ratchet

if [ "$UPDATE_BASELINE" -eq 1 ]; then
    write_baseline || FAILURES=$((FAILURES + 1))
fi

GATE_TOOK=$(format_duration $(( ($(date +%s%N) - GATE_START) / 1000000 )))
if [ "$FAILURES" -gt 0 ]; then
    warn "gate: $FAILURES check(s) failed ($GATE_TOOK)"
    exit 1
fi
success "gate: all checks passed ($GATE_TOOK)"
