#!/usr/bin/env bash
# Bounded, read-only proof that the active OMP runtime matches this kit and the local gate is green.

verify_omp_runtime() {
    local dest module_root runtime expected_hash runtime_hash runtime_path
    dest="$HOME/.omp/agent/extensions/substrate-quality.ts"
    module_root="$HOME/.omp/agent/extensions/substrate-quality"
    runtime="$HOME/.omp/run/substrate-quality.json"

    if [ ! -f "$dest" ] || [ ! -f "$module_root/runtime.ts" ] \
        || [ ! -f "$module_root/lifecycle.ts" ] || [ ! -f "$module_root/identity.ts" ] \
        || [ ! -f "$module_root/policy.ts" ] || [ ! -f "$module_root/transactions.ts" ] \
        || [ ! -f "$module_root/restructure.ts" ]; then
        warn "OMP runtime is not installed — run: substrate bootstrap"
        return 1
    fi
    if ! cmp -s "$dest" "$KIT_ROOT/core/omp/substrate-quality.ts" \
        || ! cmp -s "$module_root/runtime.ts" "$KIT_ROOT/core/omp/substrate-quality/runtime.ts" \
        || ! cmp -s "$module_root/lifecycle.ts" "$KIT_ROOT/core/omp/substrate-quality/lifecycle.ts" \
        || ! cmp -s "$module_root/identity.ts" "$KIT_ROOT/core/omp/substrate-quality/identity.ts" \
        || ! cmp -s "$module_root/policy.ts" "$KIT_ROOT/core/omp/substrate-quality/policy.ts" \
        || ! cmp -s "$module_root/transactions.ts" "$KIT_ROOT/core/omp/substrate-quality/transactions.ts" \
        || ! cmp -s "$module_root/restructure.ts" "$KIT_ROOT/core/omp/substrate-quality/restructure.ts"; then
        warn "OMP runtime is stale — run: substrate bootstrap"
        return 1
    fi
    read -r expected_hash _ < <(
        cat "$KIT_ROOT/core/omp/substrate-quality.ts" \
            "$KIT_ROOT/core/omp/substrate-quality/runtime.ts" \
            "$KIT_ROOT/core/omp/substrate-quality/lifecycle.ts" \
            "$KIT_ROOT/core/omp/substrate-quality/identity.ts" \
            "$KIT_ROOT/core/omp/substrate-quality/policy.ts" \
            "$KIT_ROOT/core/omp/substrate-quality/transactions.ts" \
            "$KIT_ROOT/core/omp/substrate-quality/restructure.ts" |
            sha256sum
    )
    if [ ! -f "$runtime" ] || ! jq -e . "$runtime" >/dev/null 2>&1; then
        warn "OMP runtime has not been observed — start OMP, then retry"
        return 1
    fi
    runtime_hash=$(jq -r '.extensionHash // empty' "$runtime")
    runtime_path=$(jq -r '.extensionPath // empty' "$runtime")
    if [ "$runtime_hash" != "$expected_hash" ] || [ "$runtime_path" != "$(realpath "$dest")" ]; then
        warn "OMP loaded a different runtime — restart OMP, then retry"
        return 1
    fi
    success "OMP runtime current (sha256 ${expected_hash:0:12})"
}

cmd_verify() {
    local gate_output gate_rc
    [ "$#" -eq 0 ] || die "verify takes no arguments"
    [ -x .substrate/gate.sh ] || die "no .substrate here — run: substrate init"
    verify_omp_runtime || return 1
    info "checking bounded local gate"
    gate_output=$(.substrate/gate.sh 2>&1)
    gate_rc=$?
    if [ "$gate_rc" -ne 0 ]; then
        printf '%s\n' "$gate_output"
        warn "Substrate is not ready — fix the reported gate failure"
        return "$gate_rc"
    fi
    success "Substrate ready — runtime current, gate green, no push performed"
}
