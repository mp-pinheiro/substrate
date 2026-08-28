# Deterministic fixture behind the golden vectors, shared by the capture script
# and its verification oracle: both must emit identical bytes, so the fixture,
# the gate invocation, and the metrics replay live in exactly one place.
# No shebang — sourced only. Callers set KIT_ROOT, GOLDEN_LABEL and LC_ALL=C,
# put the pinned jq first in PATH, then call golden_assert_toolchain.

GOLDEN_DIR="$KIT_ROOT/test/golden"
GOLDEN_JQ="$KIT_ROOT/test/.toolchain/bin/jq"
GOLDEN_JQ_VERSION=jq-1.7.1
GOLDEN_BASELINE=substrate-baseline.json
# WHY: the vector cannot be named substrate-baseline.json — protect-paths.sh:52
# blocks that basename anywhere in the tree, so an agent could never commit it.
GOLDEN_BASELINE_VECTOR=baseline.json
GOLDEN_METRICS=metrics.jsonl
GOLDEN_CLAIMS=claims.0x1f
GOLDEN_MANIFEST=manifest.json
GOLDEN_VECTORS=("$GOLDEN_BASELINE_VECTOR" "$GOLDEN_METRICS" "$GOLDEN_CLAIMS")
GOLDEN_PROBE_CHECK=35-golden-probe.sh
GOLDEN_FILE_LIST=.golden-file-list
GOLDEN_ROOT=""

# WHY: this order IS the CLAIMS row order and the comment-scan order (LC_ALL=C
# sorted), and it covers both profiles, all three claim modes, an extensionless
# shebang claim, and a ledgered ast claim whose ast_lang column must stay frozen.
GOLDEN_INVENTORY=(
    ci/pipeline.yml
    config/settings.json
    docs/notes.yaml
    lib/legacy.sh
    tools/deploy
    tools/setup.zsh
)

golden_fail() {
    printf '\033[0;31m[XX]\033[0m %s: %s\n' "${GOLDEN_LABEL:-golden}" "$*" >&2
    exit 1
}

golden_ok() {
    printf '\033[0;32m[ok]\033[0m %s: %s\n' "${GOLDEN_LABEL:-golden}" "$*"
}

golden_file_sha256() {
    local hash
    read -r hash _ < <(sha256sum "$1") || return 1
    [ -n "$hash" ] || return 1
    printf '%s\n' "$hash"
}

# Loud on every mismatch, never a skip: a vector produced by an unpinned
# toolchain is worse than no vector.
golden_assert_toolchain() {
    local id resolved
    [ "${BASH_VERSINFO[0]}" -eq 5 ] && [ "${BASH_VERSINFO[1]}" -eq 2 ] \
        || golden_fail "bash $BASH_VERSION is not 5.2.* — the vectors are frozen under bash 5.2"
    [ -x "$GOLDEN_JQ" ] \
        || golden_fail "pinned jq absent: $GOLDEN_JQ — run: test/ci-toolchain.sh --ensure-jq"
    id=$("$GOLDEN_JQ" --version 2>/dev/null) \
        || golden_fail "pinned jq will not execute: $GOLDEN_JQ"
    [ "$id" = "$GOLDEN_JQ_VERSION" ] \
        || golden_fail "pinned jq reports $id, want $GOLDEN_JQ_VERSION"
    resolved=$(command -v jq) || golden_fail "no jq on PATH"
    [ "$resolved" = "$GOLDEN_JQ" ] \
        || golden_fail "jq on PATH is $resolved, not the pinned $GOLDEN_JQ"
}

golden_write_fixture_files() {
    local root="$1" dir
    for dir in ci config docs lib tools; do
        mkdir -p "$root/$dir" || golden_fail "cannot create $root/$dir"
    done
    cat > "$root/ci/pipeline.yml" <<'YML'
name: pipeline
on:
  push:
    branches: [main]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: printf 'build\n'
YML
    cat > "$root/config/settings.json" <<'JSON'
{
  "name": "golden",
  "retries": 3
}
JSON
    cat > "$root/docs/notes.yaml" <<'YAML'
# TODO: pin the schema version
name: golden
values:
  - alpha
  - beta
# ------------------------------
retries: 3
YAML
    cat > "$root/lib/legacy.sh" <<'SH'
#!/usr/bin/env bash
set -uo pipefail

printf 'legacy\n'
SH
    cat > "$root/tools/deploy" <<'ZSH'
#!/usr/bin/env zsh
target=${1:-staging}

print "deploying to $target"
# Now we roll the canaries forward
print "canary"
ZSH
    cat > "$root/tools/setup.zsh" <<'ZSH'
#!/usr/bin/env zsh
set -e

# validate the payload before upload
print "checking"
cat <<'EOF'
# banner: ----------------------
EOF
print "done"
ZSH
    chmod +x "$root/lib/legacy.sh" "$root/tools/deploy" \
        || golden_fail "cannot mark the fixture executables"
}

golden_write_config() {
    jq -n '{
        version: 1,
        profiles: ["base", "shell"],
        inventory: "auto",
        unscanned: [".substrate/**", "*.md", "**/*.md", ".gitignore", "justfile", "lib/legacy.sh"],
        protected_paths: [],
        comment: { allow_tags: ["SAFETY:", "WHY:", "PERF:", "HACK:"] },
        budgets: { max_file_lines: 750 },
        duplication: { min_tokens: 35 },
        checks: {
            disabled: [
                "20-duplication.sh", "40-data-validity.sh", "50-gitleaks.sh",
                "59-actionlint.sh", "60-shellcheck.sh"
            ],
            config: {}
        },
        scopes: {}
    }' > "$1/substrate.json" || golden_fail "fixture substrate.json write failed"
}

# WHY: written after init — vendor_core swaps .substrate wholesale, so a probe
# staged earlier would be discarded with the old tree.
golden_write_probe() {
    local dest="$1/.substrate/checks.d/$GOLDEN_PROBE_CHECK"
    cat > "$dest" <<'SH'
#!/usr/bin/env bash
# Frozen metric shapes: one ratcheted-low value, one ratcheted-high value, so
# the JSONL dir key and the baseline direction map are both under the vector.
set -uo pipefail
# shellcheck source=../gate-lib.sh
source "$SUBSTRATE_DIR/gate-lib.sh"

metric golden:probe_lo 7
metric_hi golden:probe_hi 3
exit 0
SH
    chmod +x "$dest" || golden_fail "cannot install the fixture probe check"
}

golden_build_fixture() {
    local root="$1" log
    golden_write_fixture_files "$root"
    golden_write_config "$root"
    log=$(mktemp) || golden_fail "mktemp failed"
    if ! (
        cd "$root" || exit 2
        git init -q -b main || exit 2
        git config user.name substrate || exit 2
        git config user.email substrate@localhost || exit 2
        export SUBSTRATE_VENDOR_FROM_WORKTREE=1
        "$KIT_ROOT/bin/substrate" init --profile shell --vcs git
    ) > "$log" 2>&1; then
        cat "$log" >&2
        rm -f "$log"
        golden_fail "substrate init failed on the fixture"
    fi
    rm -f "$log"
    golden_write_probe "$root"
    printf '%s\n' "${GOLDEN_INVENTORY[@]}" > "$root/$GOLDEN_FILE_LIST" \
        || golden_fail "cannot write the fixture file list"
}

# WHY: SUBSTRATE_FILE_LIST pins the inventory to the fixture's own files —
# a VCS listing would drag every scaffold file init installs into the CLAIMS
# vector and churn it on unrelated kit changes.
golden_run_gate() {
    local root="$1" claims="$2" metrics_sink="$3" log rc
    log=$(mktemp) || golden_fail "mktemp failed"
    (
        cd "$root" || exit 2
        export SUBSTRATE_CLAIMS_OUT="$claims"
        export SUBSTRATE_METRICS_OUT="$metrics_sink"
        export SUBSTRATE_ENGINE="${GOLDEN_ENGINE:-go}"
        export SUBSTRATE_GATE_JOBS=4
        export SUBSTRATE_FILE_LIST="$root/$GOLDEN_FILE_LIST"
        substrate-engine gate --update-baseline
    ) > "$log" 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then
        cat "$log" >&2
        rm -f "$log"
        golden_fail "fixture gate --update-baseline exited $rc — vectors are only valid on a green run"
    fi
    rm -f "$log"
    [ -f "$root/$GOLDEN_BASELINE" ] || golden_fail "the gate wrote no baseline into the fixture"
    [ -s "$claims" ] \
        || golden_fail "SUBSTRATE_CLAIMS_OUT produced nothing — gate.sh must honor it (item 0.4)"
    [ -s "$metrics_sink" ] \
        || golden_fail "SUBSTRATE_METRICS_OUT produced nothing — gate.sh must honor it (item 0.5)"
}

golden_replay_metrics() {
    local root="$1" claims="$2" out="$3" chk name disabled log rc
    disabled=$(jq -c '.checks.disabled // []' "$root/substrate.json") \
        || golden_fail "cannot read checks.disabled from the fixture config"
    : > "$out" || golden_fail "cannot write $out"
    for chk in "$root"/.substrate/checks.d/*.sh; do
        [ -f "$chk" ] || continue
        name=$(basename "$chk")
        jq -e --arg n "$name" 'index($n) != null' <<< "$disabled" >/dev/null && continue
        log=$(mktemp) || golden_fail "mktemp failed"
        (
            cd "$root" || exit 2
            export SUBSTRATE_DIR="$root/.substrate" REPO_ROOT="$root" \
                CONFIG="$root/substrate.json" LANGMAP="$root/.substrate/langmap.json" \
                BASELINE="$root/$GOLDEN_BASELINE" INVENTORY="$root/$GOLDEN_FILE_LIST" \
                CLAIMS="$claims" METRICS="$out" SUBSTRATE_CHECK_NAME="$name"
            bash "$chk"
        ) > "$log" 2>&1
        rc=$?
        if [ "$rc" -ne 0 ]; then
            cat "$log" >&2
            rm -f "$log"
            golden_fail "check $name exits $rc on the captured fixture — the replay is not the runner's"
        fi
        rm -f "$log"
    done
    [ -s "$out" ] || golden_fail "no metrics emitted — the fixture lost its metric-producing checks"
}

# Rebuilds the baseline from the replayed JSONL and byte-matches
# internal/gate/baseline.go's marshalBaseline (flat 2-space indent, no compounding).
golden_render_go_baseline() {
    local metrics_json="$1" direction_json="$2" out="$3"
    {
        printf '{\n'
        printf '  "metrics": {\n'
        local -a mlines=()
        mapfile -t mlines < <(jq -r 'to_entries[] | "\(.key)\t\(.value)"' <<< "$metrics_json")
        local i n=${#mlines[@]} k v
        for ((i = 0; i < n; i++)); do
            IFS=$'\t' read -r k v <<< "${mlines[$i]}"
            if [ "$i" -lt $((n - 1)) ]; then
                printf '  "%s": %s,\n' "$k" "$v"
            else
                printf '  "%s": %s\n' "$k" "$v"
            fi
        done
        printf '},\n'
        printf '  "direction": {\n'
        local -a dlines=()
        mapfile -t dlines < <(jq -r 'to_entries[] | "\(.key)\t\(.value)"' <<< "$direction_json")
        n=${#dlines[@]}
        for ((i = 0; i < n; i++)); do
            IFS=$'\t' read -r k v <<< "${dlines[$i]}"
            if [ "$i" -lt $((n - 1)) ]; then
                printf '  "%s": "%s",\n' "$k" "$v"
            else
                printf '  "%s": "%s"\n' "$k" "$v"
            fi
        done
        printf '}\n'
        printf '}\n'
    } > "$out"
}

golden_assert_baseline_reproducible() {
    local metrics="$1" baseline="$2" current direction tmp
    current=$(jq -sc 'map({(.name): .value}) | add // {} | to_entries | sort_by(.key) | from_entries' "$metrics") \
        || golden_fail "metrics aggregation failed"
    direction=$(jq -sc 'map({(.name): (.dir // "lo")}) | add // {} | to_entries | sort_by(.key) | from_entries' "$metrics") \
        || golden_fail "direction aggregation failed"
    tmp=$(mktemp) || golden_fail "mktemp failed"
    golden_render_go_baseline "$current" "$direction" "$tmp" || golden_fail "baseline rebuild failed"
    if ! cmp -s "$tmp" "$baseline"; then
        diff -u "$baseline" "$tmp" >&2
        rm -f "$tmp"
        golden_fail "replayed metrics do not rebuild the gate's baseline"
    fi
    rm -f "$tmp"
}

# Guards against silent fixture rot: a vector that stopped covering its shapes
# still compares green forever.
golden_assert_coverage() {
    local claims="$1" metrics="$2" path profile ast mode entry
    local rows=0 seen_ast=0 seen_line=0 seen_exempt=0 hi comments
    while IFS=$'\x1f' read -r path profile ast mode entry; do
        [ -n "$path" ] || continue
        [ -n "$profile" ] || golden_fail "claims row without a profile: $path"
        [ -n "$entry" ] || golden_fail "claims row without an entry: $path"
        rows=$((rows + 1))
        case "$mode" in
            ast) seen_ast=1; [ -n "$ast" ] || golden_fail "ast claim without ast_lang: $path" ;;
            line) seen_line=1 ;;
            exempt) seen_exempt=1 ;;
            *) golden_fail "unknown claim mode '$mode' for $path" ;;
        esac
    done < "$claims"
    [ "$rows" -eq "${#GOLDEN_INVENTORY[@]}" ] \
        || golden_fail "claims vector has $rows rows, fixture claims ${#GOLDEN_INVENTORY[@]}"
    [ "$seen_ast" -eq 1 ] && [ "$seen_line" -eq 1 ] && [ "$seen_exempt" -eq 1 ] \
        || golden_fail "claims vector lost a mode (ast=$seen_ast line=$seen_line exempt=$seen_exempt)"
    hi=$(jq -s '[.[] | select(.dir == "hi")] | length' "$metrics") \
        || golden_fail "metrics vector is not readable jsonl"
    [ "$hi" -ge 1 ] || golden_fail "metrics vector has no ratchet-high metric — the dir key is unfrozen"
    comments=$(jq -s '[.[] | select(.name | startswith("comments:"))] | length' "$metrics") \
        || golden_fail "metrics vector is not readable jsonl"
    [ "$comments" -ge 2 ] \
        || golden_fail "metrics vector lost its comment-slop metrics — the offending files stopped offending"
}

# Fixture inputs only: the vendored .substrate tree is the engine under test,
# so engine drift must land in the vectors, never in this hash.
golden_fixture_hash() {
    local root="$1" listing rel hash
    listing=$(mktemp) || return 1
    for rel in substrate.json ".substrate/checks.d/$GOLDEN_PROBE_CHECK" "${GOLDEN_INVENTORY[@]}"; do
        hash=$(golden_file_sha256 "$root/$rel") || { rm -f "$listing"; return 1; }
        printf '%s  %s\n' "$hash" "$rel" >> "$listing" || { rm -f "$listing"; return 1; }
    done
    hash=$(golden_file_sha256 "$listing") || { rm -f "$listing"; return 1; }
    rm -f "$listing"
    printf '%s\n' "$hash"
}

golden_regenerate() {
    local scratch="$1" out="$2"
    local claims="$scratch/$GOLDEN_CLAIMS" sink="$scratch/$GOLDEN_METRICS.sink" metrics="$scratch/$GOLDEN_METRICS"
    GOLDEN_ROOT="$scratch/repo"
    # SAFETY: scratch HOME — a fixture init must never reach the caller's harness
    export HOME="$scratch/home"
    export SUBSTRATE_NO_USER_HARNESS=1
    mkdir -p "$HOME" "$GOLDEN_ROOT" "$out" || golden_fail "cannot prepare $scratch"
    golden_build_fixture "$GOLDEN_ROOT"
    golden_run_gate "$GOLDEN_ROOT" "$claims" "$sink"
    golden_replay_metrics "$GOLDEN_ROOT" "$claims" "$metrics"
    golden_assert_baseline_reproducible "$metrics" "$GOLDEN_ROOT/$GOLDEN_BASELINE"
    golden_assert_coverage "$claims" "$metrics"
    cp "$GOLDEN_ROOT/$GOLDEN_BASELINE" "$out/$GOLDEN_BASELINE_VECTOR" \
        || golden_fail "baseline copy failed"
    cmp -s "$sink" "$metrics" \
        || golden_fail "SUBSTRATE_METRICS_OUT differs from replay — metrics sink captured wrong bytes"
    cp "$metrics" "$out/$GOLDEN_METRICS" || golden_fail "metrics copy failed"
    cp "$claims" "$out/$GOLDEN_CLAIMS" || golden_fail "claims copy failed"
}

golden_write_manifest() {
    local root="$1" dir="$2" fixture jqsha entries name hash vectors
    fixture=$(golden_fixture_hash "$root") || golden_fail "fixture hash failed"
    jqsha=$(golden_file_sha256 "$GOLDEN_JQ") || golden_fail "pinned jq hash failed"
    entries=$(mktemp) || golden_fail "mktemp failed"
    for name in "${GOLDEN_VECTORS[@]}"; do
        hash=$(golden_file_sha256 "$dir/$name") || golden_fail "cannot hash $name"
        jq -cn --arg key "$name" --arg value "$hash" '{key: $key, value: $value}' >> "$entries" \
            || golden_fail "manifest entry failed: $name"
    done
    vectors=$(jq -sc 'from_entries' "$entries") || golden_fail "manifest vector map failed"
    rm -f "$entries"
    jq -n --arg bash "$BASH_VERSION" --arg jq "$GOLDEN_JQ_VERSION" --arg jqsha "$jqsha" \
        --arg engine "${GOLDEN_ENGINE:-go}" \
        --arg fixture "$fixture" --argjson vectors "$vectors" \
        '{format: 1,
          engine: $engine,
          tools: {bash: $bash, jq: $jq, jq_sha256: $jqsha},
          fixture_sha256: $fixture,
          vectors: $vectors}' > "$dir/$GOLDEN_MANIFEST" \
        || golden_fail "manifest write failed"
}

golden_assert_manifest_integrity() {
    local root="$1" fixture recorded actual name engine recorded_engine
    if [ ! -f "$GOLDEN_DIR/$GOLDEN_MANIFEST" ]; then
        golden_fail "test/golden/$GOLDEN_MANIFEST absent — capture with: bash test/capture-golden-vectors.sh"
    fi
    fixture=$(golden_fixture_hash "$root") || golden_fail "fixture hash failed"
    engine="${GOLDEN_ENGINE:-go}"
    recorded_engine=$(jq -r '.engine // empty' "$GOLDEN_DIR/$GOLDEN_MANIFEST") \
        || golden_fail "manifest is not readable json"
    [ "$engine" = "$recorded_engine" ] \
        || golden_fail "engine $engine does not match manifest engine $recorded_engine — recapture"
    recorded=$(jq -r '.fixture_sha256 // empty' "$GOLDEN_DIR/$GOLDEN_MANIFEST") \
        || golden_fail "manifest is not readable json"
    [ "$fixture" = "$recorded" ] \
        || golden_fail "fixture hash $fixture is not the manifest's $recorded — the fixture changed; recapture deliberately"
    for name in "${GOLDEN_VECTORS[@]}"; do
        [ -f "$GOLDEN_DIR/$name" ] \
            || golden_fail "committed vector absent: test/golden/$name"
        recorded=$(jq -r --arg name "$name" '.vectors[$name] // empty' "$GOLDEN_DIR/$GOLDEN_MANIFEST") \
            || golden_fail "manifest is not readable json"
        actual=$(golden_file_sha256 "$GOLDEN_DIR/$name") || golden_fail "cannot hash test/golden/$name"
        [ "$recorded" = "$actual" ] \
            || golden_fail "test/golden/$name was hand-edited (manifest $recorded, file $actual)"
    done
}

golden_compare_vectors() {
    local fresh="$1" name rc=0
    for name in "${GOLDEN_VECTORS[@]}"; do
        if cmp -s "$GOLDEN_DIR/$name" "$fresh/$name"; then
            golden_ok "$name byte-identical"
        else
            printf 'vector drift: test/golden/%s\n' "$name" >&2
            diff -u "$GOLDEN_DIR/$name" "$fresh/$name" 2>&1 | head -40 >&2
            rc=1
        fi
    done
    [ "$rc" -eq 0 ] \
        || golden_fail "regenerated vectors diverge from test/golden — the frozen bytes moved"
}
