#!/usr/bin/env bash
# Scenario A/B harness: one measured command per scenario in a scratch tree,
# with normalized {stdout, stderr, exit, watched state} byte-compared against a
# recorded expectation. AB_MODE=capture records it, AB_MODE=verify (default)
# diffs against it and fails loud; AB_EXPECTED_ROOT retargets the recording, so
# a capture taken from one implementation can judge another.
# The measured run inherits the ambient environment, so SUBSTRATE_ENGINE and
# friends select an implementation without this harness knowing one exists.
# Volatile bytes (absolute paths, session ids, commit ids, hashes, timestamps)
# are masked before comparison; scenario literals register through ab_mask.

AB_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AB_KIT_ROOT="$(cd "$AB_LIB_DIR/../.." && pwd)"
AB_VOLATILE_RE='[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}:[0-9]{2}([.,][0-9]+)?(Z|[+-][0-9]{2}:?[0-9]{2})?|[0-9a-f]{64}|[0-9a-f]{40}'

ab_init() {
    AB_SUITE="$1"
    AB_MODE="${AB_MODE:-verify}"
    case "$AB_MODE" in
        capture|verify) ;;
        *) printf 'ab-diff: AB_MODE must be capture or verify (got %s)\n' "$AB_MODE" >&2; return 2 ;;
    esac
    AB_EXPECTED_ROOT="${AB_EXPECTED_ROOT:-$AB_KIT_ROOT/test/expected/$AB_SUITE}"
    AB_WORK="${AB_WORK:-${TMPDIR:-/tmp}/ab-$AB_SUITE.$$}"
    mkdir -p "$AB_WORK" || return 2
    AB_WORK=$(cd "$AB_WORK" && pwd -P) || return 2
    AB_PASS=0
    AB_DIVERGED=0
    AB_FAIL=0
    AB_SCENARIO=""
    AB_SCENARIO_FAIL=0
    printf '%s: mode=%s engine=%s expected=%s work=%s\n' \
        "$AB_SUITE" "$AB_MODE" "${SUBSTRATE_ENGINE:-auto}" "$AB_EXPECTED_ROOT" "$AB_WORK"
}

ab_begin() {
    AB_SCENARIO="$1"
    AB_SCENARIO_DIR="$AB_WORK/$AB_SCENARIO"
    AB_LIVE="$AB_SCENARIO_DIR/live"
    AB_RAW="$AB_SCENARIO_DIR/raw"
    AB_SHIM="$AB_SCENARIO_DIR/shim"
    AB_SCENARIO_FAIL=0
    AB_MASK_FROM=()
    AB_MASK_TO=()
    AB_WATCH=()
    AB_ENV=()
    rm -rf "$AB_SCENARIO_DIR" || return 2
    mkdir -p "$AB_LIVE" "$AB_RAW" "$AB_SHIM/bin" "$AB_SHIM/log"
}

# masks apply longest literal first: a repo root that contains the session id
# must never be half-masked by the shorter literal
ab_mask() {
    local from="$1" to="$2" at=0
    while [ "$at" -lt "${#AB_MASK_FROM[@]}" ] && [ "${#AB_MASK_FROM[$at]}" -ge "${#from}" ]; do
        at=$((at + 1))
    done
    AB_MASK_FROM=("${AB_MASK_FROM[@]:0:$at}" "$from" "${AB_MASK_FROM[@]:$at}")
    AB_MASK_TO=("${AB_MASK_TO[@]:0:$at}" "$to" "${AB_MASK_TO[@]:$at}")
}

ab_watch() {
    local path
    for path in "$@"; do
        case "$path" in
            ''|/*|../*|*/../*) printf 'ab-diff: unsafe watch path: %s\n' "$path" >&2; return 2 ;;
        esac
        AB_WATCH+=("$path")
    done
}

ab_env() {
    [ "$#" -eq 0 ] || AB_ENV+=("$@")
}

# wrappers count invocations, then exec the real binary; a spec is `name`
# (resolved on PATH) or `name=/path/to/binary` when a scenario injects a fault
ab_shim() {
    local spec name real
    for spec in "$@"; do
        name="${spec%%=*}"
        real="${spec#*=}"
        if [ "$real" = "$spec" ]; then
            real=$(command -v "$name") \
                || { printf 'ab-diff: no %s on PATH to shim\n' "$name" >&2; return 2; }
        fi
        case "$real$AB_SHIM" in
            *\'*) printf 'ab-diff: quote-hostile path for the %s shim\n' "$name" >&2; return 2 ;;
        esac
        : > "$AB_SHIM/log/$name" || return 2
        cat > "$AB_SHIM/bin/$name" <<EOF
#!/usr/bin/env bash
printf '%s\n' '$name' >> '$AB_SHIM/log/$name'
exec '$real' "\$@"
EOF
        chmod +x "$AB_SHIM/bin/$name" || return 2
    done
    ab_env "PATH=$AB_SHIM/bin:$PATH"
}

ab_run() {
    local cwd="$1" payload="$2" rc
    shift 2
    printf '%s' "$payload" > "$AB_RAW/stdin"
    (
        cd "$cwd" || exit 9
        exec env ${AB_ENV[@]+"${AB_ENV[@]}"} "$@"
    ) < "$AB_RAW/stdin" > "$AB_RAW/stdout" 2> "$AB_RAW/stderr"
    rc=$?
    printf '%d\n' "$rc" > "$AB_LIVE/exit.txt"
    ab_normalize "$AB_RAW/stdout" "$AB_LIVE/stdout.txt"
    ab_normalize "$AB_RAW/stderr" "$AB_LIVE/stderr.txt"
    ab_collect_state "$cwd" > "$AB_RAW/state"
    ab_normalize "$AB_RAW/state" "$AB_LIVE/state.txt"
    return "$rc"
}

ab_collect_state() {
    local path
    for path in ${AB_WATCH[@]+"${AB_WATCH[@]}"}; do
        ab_record_path "$1" "$path"
    done
}

ab_record_path() {
    local cwd="$1" path="$2" full="$1/$2" entry
    if [ -L "$full" ]; then
        printf -- '--- %s symlink %s\n' "$path" "$(readlink "$full")"
    elif [ -f "$full" ]; then
        printf -- '--- %s file\n' "$path"
        cat "$full"
        [ -z "$(tail -c 1 "$full")" ] || printf '\n--- no-trailing-newline\n'
    elif [ -d "$full" ]; then
        printf -- '--- %s dir\n' "$path"
        while IFS= read -r -d '' entry; do
            ab_record_path "$cwd" "$path/${entry#"$full"/}"
        done < <(find "$full" -mindepth 1 -maxdepth 1 -print0 | LC_ALL=C sort -z)
    else
        printf -- '--- %s missing\n' "$path"
    fi
}

ab_normalize() {
    ab_normalize_stream < "$1" > "$2"
}

# SAFETY: a missing final newline is a byte-level fact, so the last partial
# line is written back without one
ab_normalize_stream() {
    local line last=0
    while [ "$last" -eq 0 ]; do
        IFS= read -r line || last=1
        if [ "$last" -eq 1 ] && [ -z "$line" ]; then
            break
        fi
        ab_mask_apply "$line"
        if [ "$last" -eq 1 ]; then
            printf '%s' "$AB_MASKED"
        else
            printf '%s\n' "$AB_MASKED"
        fi
    done
}

ab_mask_apply() {
    local text="$1" out="" at=0 match prefix token
    while [ "$at" -lt "${#AB_MASK_FROM[@]}" ]; do
        text="${text//"${AB_MASK_FROM[$at]}"/"${AB_MASK_TO[$at]}"}"
        at=$((at + 1))
    done
    while [[ "$text" =~ $AB_VOLATILE_RE ]]; do
        match="${BASH_REMATCH[0]}"
        prefix="${text%%"$match"*}"
        case "$match" in
            *:*) token='<TS>' ;;
            *)
                if [ "${#match}" -eq 64 ]; then token='<SHA256>'; else token='<HEX40>'; fi
                ;;
        esac
        out+="$prefix$token"
        text="${text:$(( ${#prefix} + ${#match} ))}"
    done
    AB_MASKED="$out$text"
}

ab_spawns() {
    local log="$AB_SHIM/log/$1"
    if [ -f "$log" ]; then
        wc -l < "$log"
    else
        printf '0\n'
    fi
}

ab_ceiling() {
    local name="$1" max="$2" count
    count=$(ab_spawns "$name")
    if [ "$AB_MODE" = capture ]; then
        printf '  [--] %s: %s spawns=%s (ceiling %s unenforced while capturing)\n' \
            "$AB_SCENARIO" "$name" "$count" "$max"
        return 0
    fi
    if [ "$count" -gt "$max" ]; then
        ab_fail "$name spawned $count times, ceiling $max"
        return 1
    fi
    printf '  [ok] %s: %s spawns=%s within ceiling %s\n' "$AB_SCENARIO" "$name" "$count" "$max"
}

ab_fail() {
    printf '  [XX] %s: %s\n' "$AB_SCENARIO" "$1" >&2
    AB_SCENARIO_FAIL=1
    return 1
}

ab_end() {
    local expected="$AB_EXPECTED_ROOT/$AB_SCENARIO" reason="" ab_diverged_ok=0
    declare -F ab_known_divergence_reason >/dev/null 2>&1 \
        && reason=$(ab_known_divergence_reason "$AB_SCENARIO")
    if [ "$AB_MODE" = capture ]; then
        rm -rf "$expected"
        if mkdir -p "$expected" && cp "$AB_LIVE"/*.txt "$expected/"; then
            printf '  [==] %s: recorded into %s\n' "$AB_SCENARIO" "$expected"
        else
            ab_fail "recording into $expected failed"
        fi
    elif [ ! -d "$expected" ]; then
        ab_fail "no recording at $expected — capture it: AB_MODE=capture bash test/$AB_SUITE-test.sh"
    elif diff -ru "$expected" "$AB_LIVE"; then
        if [ -n "$reason" ]; then
            ab_fail "registered as a known divergence but the legs now AGREE — remove it from the registry"
        else
            printf '  [ok] %s: stdout, stderr, exit and state byte-identical\n' "$AB_SCENARIO"
        fi
    elif [ -n "$reason" ]; then
        printf '  [~~] %s: expected divergence — %s\n' "$AB_SCENARIO" "$reason"
        ab_diverged_ok=1
    else
        ab_fail "live run diverged from $expected"
    fi
    if [ "$AB_SCENARIO_FAIL" -ne 0 ]; then
        AB_FAIL=$((AB_FAIL + 1))
    elif [ "$ab_diverged_ok" -eq 1 ]; then
        AB_DIVERGED=$((AB_DIVERGED + 1))
    else
        AB_PASS=$((AB_PASS + 1))
    fi
    [ "$AB_SCENARIO_FAIL" -eq 0 ]
}

ab_report() {
    if [ "$AB_DIVERGED" -eq 0 ]; then
        printf '%s: %d scenarios green, %d failed (mode %s)\n' \
            "$AB_SUITE" "$AB_PASS" "$AB_FAIL" "$AB_MODE"
    else
        printf '%s: %d scenarios green, %d expected divergence, %d failed (mode %s)\n' \
            "$AB_SUITE" "$AB_PASS" "$AB_DIVERGED" "$AB_FAIL" "$AB_MODE"
    fi
    [ "$AB_FAIL" -eq 0 ]
}

