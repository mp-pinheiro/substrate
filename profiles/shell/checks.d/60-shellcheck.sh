#!/usr/bin/env bash
# Lints claimed shell files: executables (own shebang) get the full shellcheck
# treatment; sourced fragments run as bash with the cross-file noise excluded.
# zsh files have no shellcheck support — `zsh -n` syntax-checks them instead.
# Shellcheck is single-threaded, so the executable and fragment lists are split
# into nproc batches dispatched concurrently; each batch writes to its own file
# then they are emitted in order so findings never interleave.
set -uo pipefail
# shellcheck source=../gate-lib.sh
source "$SUBSTRATE_DIR/gate-lib.sh"

executables=()
fragments=()
while IFS= read -r f; do
    first=""
    { IFS= read -r first < "$f"; } 2>/dev/null
    if [ "${first:0:2}" = "#!" ]; then
        executables+=("$f")
    else
        fragments+=("$f")
    fi
done < <(profile_files shell bash scan_target)
zsh_files=()
while IFS= read -r f; do
    zsh_files+=("$f")
done < <(profile_files shell zsh scan_target)

rc=0

# ~/.shellcheckrc survives XDG scrubbing (probed v0.11): --norc unless the gate:allow-comment
# repo has its own rc — the upward walk then stops at repo ancestors
# before ever reaching HOME.
sc_args=(-S warning)
if [ ! -f "$REPO_ROOT/.shellcheckrc" ]; then
    sc_args+=(--norc)
fi
# Split the named array into ceil(n/sc_max) concurrent batches; each batch's
# output is captured separately and emitted in order to avoid interleaving.
sc_parallel() {
    local -n sc_files=$1; shift
    local n=${#sc_files[@]}
    [ "$n" -eq 0 ] && return 0
    local sc_max
    sc_max=$(nproc 2>/dev/null) || sc_max=4
    case "$sc_max" in ([1-9]*) ;; *) sc_max=4 ;; esac
    local batch=$(( (n + sc_max - 1) / sc_max ))
    [ "$batch" -ge 1 ] 2>/dev/null || batch=1
    local out_dir start=0 idx=0 any=0 pid j
    out_dir=$(mktemp -d)
    local pids=()
    while [ "$start" -lt "$n" ]; do
        local end=$(( start + batch ))
        [ "$end" -gt "$n" ] && end=$n
        local slice=("${sc_files[@]:start:end-start}")
        shellcheck "${sc_args[@]}" "$@" "${slice[@]}" >"$out_dir/$idx.out" 2>&1 &
        pids+=($!)
        idx=$((idx+1)); start=$end
    done
    for pid in "${pids[@]}"; do
        wait "$pid" || any=1
    done
    for ((j=0; j<idx; j++)); do cat "$out_dir/$j.out"; done
    rm -rf "$out_dir"
    return "$any"
}

if [ ${#executables[@]} -gt 0 ] || [ ${#fragments[@]} -gt 0 ]; then
    if require_bin_ci shellcheck "profile toolchain — see profiles/shell/profile.json"; then
        if [ ${#executables[@]} -gt 0 ]; then
            sc_parallel executables -x -e SC1091 || rc=1
        fi
        if [ ${#fragments[@]} -gt 0 ]; then
            sc_parallel fragments -s bash -e SC1091,SC2154 || rc=1
        fi
    fi
fi

if [ ${#zsh_files[@]} -gt 0 ]; then
    if have zsh; then
        for f in "${zsh_files[@]}"; do
            zsh --no-rcs -n "$f" 2>&1 || { printf 'zsh syntax: %s failed\n' "$f"; rc=1; }
        done
    else
        warn "zsh not installed — zsh syntax check skipped"
    fi
fi

exit "$rc"
