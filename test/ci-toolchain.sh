#!/usr/bin/env bash
# Executes profile ci install lines so CI never drifts from the profiles —
# new profile, new toolchain, zero workflow edits.
#   default:     every kit profile (profile-matrix job)
#   --active:    only substrate.json active profiles, kit + repo-local (gate job)
#   --ensure-jq: pinned jq 1.7.1 into test/.toolchain/bin for byte-exact oracles
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# WHY: golden vectors are jq serialization bytes, and ambient jq may be jaq,
# gojq, or 1.8 — the pin below is the only jq those oracles are allowed to use.
# sha256 from https://github.com/jqlang/jq/releases/download/jq-1.7.1/sha256sum.txt
JQ_PIN_VERSION=jq-1.7.1
case "$(uname -m)" in
    x86_64)
        JQ_PIN_ASSET=jq-linux-amd64
        JQ_PIN_SHA256=5942c9b0934e510ee61eb3e30273f1b3fe2590df93933a93d7c58b81d19c8ff5
        ;;
    aarch64)
        JQ_PIN_ASSET=jq-linux-arm64
        JQ_PIN_SHA256=4dd2d8a0661df0b22f1bb9a1f9830f06b6f3b8f7d91211a1ef5d7c4f06a8b4a5
        ;;
    *)
        printf '[ci-toolchain] unsupported architecture: %s\n' "$(uname -m)" >&2
        exit 1
        ;;
esac
JQ_PIN_BIN="$KIT_ROOT/test/.toolchain/bin/jq"

file_sha256() {
    local hash
    read -r hash _ < <(sha256sum "$1") || return 1
    [ -n "$hash" ] || return 1
    printf '%s\n' "$hash"
}

jq_pin_ok() {
    [ -x "$JQ_PIN_BIN" ] || return 1
    local hash id
    hash=$(file_sha256 "$JQ_PIN_BIN") || return 1
    [ "$hash" = "$JQ_PIN_SHA256" ] || return 1
    id=$("$JQ_PIN_BIN" --version 2>/dev/null) || return 1
    [ "$id" = "$JQ_PIN_VERSION" ]
}

# WHY: offline-safe by construction — a matching pin returns before any network
# call, so repeat runs on a provisioned tree never touch GitHub.
ensure_jq() {
    if jq_pin_ok; then
        printf '[ci-toolchain] %s present: %s\n' "$JQ_PIN_VERSION" "$JQ_PIN_BIN"
        return 0
    fi
    [ ! -e "$JQ_PIN_BIN" ] \
        || printf '[ci-toolchain] %s fails its pin — refetching\n' "$JQ_PIN_BIN" >&2
    local dir="$KIT_ROOT/test/.toolchain/bin" url staged hash
    mkdir -p "$dir" || { printf '[ci-toolchain] cannot create %s\n' "$dir" >&2; return 1; }
    url="https://github.com/jqlang/jq/releases/download/$JQ_PIN_VERSION/$JQ_PIN_ASSET"
    staged=$(mktemp "$dir/jq.XXXXXX") || { printf '[ci-toolchain] staging failed in %s\n' "$dir" >&2; return 1; }
    if ! curl -sSfL -o "$staged" "$url"; then
        rm -f "$staged"
        printf '[ci-toolchain] download failed: %s\n' "$url" >&2
        return 1
    fi
    hash=$(file_sha256 "$staged") || { rm -f "$staged"; return 1; }
    if [ "$hash" != "$JQ_PIN_SHA256" ]; then
        rm -f "$staged"
        printf '[ci-toolchain] sha256 mismatch for %s: got %s, want %s\n' "$url" "$hash" "$JQ_PIN_SHA256" >&2
        return 1
    fi
    chmod +x "$staged" || { rm -f "$staged"; return 1; }
    mv -f "$staged" "$JQ_PIN_BIN" || { rm -f "$staged"; return 1; }
    if ! jq_pin_ok; then
        printf '[ci-toolchain] %s does not run as %s\n' \
            "$JQ_PIN_BIN" "$JQ_PIN_VERSION" >&2
        return 1
    fi
    printf '[ci-toolchain] %s installed: %s\n' "$JQ_PIN_VERSION" "$JQ_PIN_BIN"
}

add_profile() {
    for dir in "$KIT_ROOT/profiles/$1" "$KIT_ROOT/substrate-profiles/$1"; do
        [ -f "$dir/profile.json" ] && { pjsons+=("$dir/profile.json"); return; }
    done
}

pjsons=()
case "${1:-}" in
    --ensure-jq)
        ensure_jq || exit 1
        exit 0
        ;;
    --active)
        while IFS= read -r name; do add_profile "$name"; done \
            < <(jq -r '.profiles[]' "$KIT_ROOT/substrate.json") ;;
    "")
        for pjson in "$KIT_ROOT"/profiles/*/profile.json; do pjsons+=("$pjson"); done ;;
    *)
        for name in base "$@"; do add_profile "$name"; done ;;
esac

for pjson in "${pjsons[@]}"; do
    name=$(jq -r '.name' "$pjson")
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        printf '[ci-toolchain] %s: %s\n' "$name" "$line"
        bash -c "$line" || { printf '[ci-toolchain] FAILED (%s): %s\n' "$name" "$line" >&2; exit 1; }
    done < <(jq -r '(.ci // [])[]' "$pjson")
done
