#!/usr/bin/env bash
# Contract drift: generated artifacts must byte-match their SSOT. Each regen
# runs in a scratch copy of the tracked tree — a red gate never mutates the
# working tree — and the diff against the repo's generated paths is the verdict.
set -uo pipefail
# shellcheck source=../gate-lib.sh
source "$SUBSTRATE_DIR/gate-lib.sh"

count=$(jq -r '(.contracts // []) | length' "$CONFIG")
[ "$count" -gt 0 ] || exit 0

jq -e '(.contracts // []) | all((.name | type == "string") and (.regen | type == "string") and (.paths | type == "array"))' "$CONFIG" >/dev/null \
    || die_infra "substrate.json contracts entries need name/regen/paths (paths: array)"

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
while IFS= read -r f; do
    [ -f "$REPO_ROOT/$f" ] || continue
    mkdir -p "$scratch/$(dirname "$f")"
    cp "$REPO_ROOT/$f" "$scratch/$f"
done < "$INVENTORY"

rc=0
i=0
while [ "$i" -lt "$count" ]; do
    name=$(jq -r ".contracts[$i].name" "$CONFIG")
    regen=$(jq -r ".contracts[$i].regen" "$CONFIG")
    gen_bin="${regen%% *}"
    if ! require_bin_ci "$gen_bin" "contract '$name' generator — substrate.json contracts[].regen"; then
        i=$((i + 1))
        continue
    fi
    if ! (cd "$scratch" && bash -c "$regen") > "$scratch/.regen-out" 2>&1; then
        cat "$scratch/.regen-out"
        die_infra "contract '$name': regen failed — the gate cannot pass blind"
    fi
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        if ! diff -r -q "$REPO_ROOT/$p" "$scratch/$p" >/dev/null 2>&1; then
            diff -ru "$REPO_ROOT/$p" "$scratch/$p" 2>&1 | head -40
            printf "contract '%s': %s drifted from its source — edit the contract, never the output; regen: %s\n" "$name" "$p" "$regen"
            rc=1
        fi
    done < <(jq -r ".contracts[$i] | (.paths // [])[]" "$CONFIG")
    i=$((i + 1))
done
exit "$rc"
