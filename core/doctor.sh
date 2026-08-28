#!/usr/bin/env bash
# Diagnostic command sourced by bin/substrate.

cmd_doctor() {
    [ -d .substrate ] || die "no .substrate here — run: substrate init"
    jq -e . substrate.json >/dev/null 2>&1 || die "substrate.json missing or corrupt"
    success "substrate.json parses"

    local profiles=()
    mapfile -t profiles < <(jq -r '.profiles[]' substrate.json)
    local fresh
    fresh=$(mktemp)
    build_langmap "$fresh" "${profiles[@]}"
    if cmp -s "$fresh" .substrate/langmap.json; then
        success "langmap fresh"
    else
        warn "langmap stale vs profiles — run: substrate update --apply"
    fi
    rm -f "$fresh"

    local event matcher command hooks_missing=0
    if [ -f .claude/settings.json ] && jq -e . .claude/settings.json >/dev/null 2>&1; then
        while IFS=$'\t' read -r event matcher command; do
            [ -n "$command" ] || continue
            if ! jq -e --arg event "$event" --arg matcher "$matcher" --arg command "$command" '
                [.hooks[$event][]?
                    | select(.matcher == $matcher)
                    | .hooks[]?
                    | select((.type == "command") and (.command == $command))]
                | length > 0
            ' .claude/settings.json >/dev/null 2>&1; then
                warn "$event hook registration missing or malformed: $command"
                hooks_missing=1
            fi
        done < <(jq -r '
            .hooks | to_entries[] | .key as $event | .value[]
            | .matcher as $matcher | .hooks[]
            | [$event, $matcher, .command] | @tsv
        ' "$KIT_ROOT/core/claude-hooks.json")
        [ "$hooks_missing" -eq 0 ] && success "claude hooks wired"
    else
        warn ".claude/settings.json absent or invalid — write-time hooks unarmed (run init)"
    fi
    if [ -e .omp/extensions/substrate-quality.ts ]; then
        local legacy_hash=""
        if [ -f .omp/extensions/substrate-quality.ts ]; then
            read -r legacy_hash _ < <(sha256sum .omp/extensions/substrate-quality.ts) || legacy_hash=unknown
        else
            legacy_hash=non-regular
        fi
        warn "repo-local omp extension can shadow the authoritative user copy (sha256 $legacy_hash) — run: substrate bootstrap"
    else
        success "repo-local omp extension absent (user-level runtime is authoritative)"
    fi
    local omp_dest="$HOME/.omp/agent/extensions/substrate-quality.ts"
    local omp_module_root="$HOME/.omp/agent/extensions/substrate-quality" expected_hash=""
    if [ -f "$omp_dest" ] && [ -f "$omp_module_root/runtime.ts" ] \
        && [ -f "$omp_module_root/lifecycle.ts" ] && [ -f "$omp_module_root/identity.ts" ]; then
        if cmp -s "$omp_dest" "$KIT_ROOT/core/omp/substrate-quality.ts" \
            && cmp -s "$omp_module_root/runtime.ts" "$KIT_ROOT/core/omp/substrate-quality/runtime.ts" \
            && cmp -s "$omp_module_root/lifecycle.ts" "$KIT_ROOT/core/omp/substrate-quality/lifecycle.ts" \
            && cmp -s "$omp_module_root/identity.ts" "$KIT_ROOT/core/omp/substrate-quality/identity.ts"; then
            read -r expected_hash _ < <(
                cat "$KIT_ROOT/core/omp/substrate-quality.ts" \
                    "$KIT_ROOT/core/omp/substrate-quality/runtime.ts" \
                    "$KIT_ROOT/core/omp/substrate-quality/lifecycle.ts" \
                    "$KIT_ROOT/core/omp/substrate-quality/identity.ts" |
                    sha256sum
            )
            success "user-level omp extension current (sha256 ${expected_hash:0:12})"
        else
            warn "user-level omp extension stale — run: substrate bootstrap"
        fi
    else
        warn "no user-level omp extension — OMP sessions run ungated"
    fi
    local runtime="$HOME/.omp/run/substrate-quality.json" runtime_hash="" runtime_extension=""
    if [ -f "$runtime" ] && jq -e . "$runtime" >/dev/null 2>&1; then
        runtime_hash=$(jq -r '.extensionHash // empty' "$runtime")
        runtime_extension=$(jq -r '.extensionPath // empty' "$runtime")
        if [ -n "$expected_hash" ] && [ "$runtime_hash" = "$expected_hash" ] \
            && [ "$runtime_extension" = "$(realpath "$omp_dest")" ]; then
            success "omp runtime loaded: $runtime_extension (sha256 ${runtime_hash:0:12})"
        else
            warn "omp runtime differs from the installed extension: ${runtime_extension:-unknown} (sha256 ${runtime_hash:-unknown}) — restart OMP"
        fi
    else
        info "omp runtime not observed yet — start or restart OMP, then run /substrate"
    fi
    info "harness hooks arm at session start — restart your agent after bootstrap/update"

    local key lbin lhint p d
    for p in "${profiles[@]}"; do
        d=$(profile_dir "$p") || continue
        while IFS=$'\t' read -r key lbin lhint; do
            [ -n "$key" ] || continue
            if command -v "$lbin" >/dev/null 2>&1; then
                success "lsp $key: $lbin present"
            else
                info "lsp $key: $lbin absent — inline diagnostics unavailable; install: $lhint"
            fi
        done < <(jq -r '(.lsp // {}) | to_entries[] | "\(.key)\t\(.value.bin)\t\(.value.hint)"' "$d/profile.json")
    done

    local c cb
    for c in checks.d/*.sh; do
        [ -f "$c" ] || continue
        cb=$(basename "$c")
        if [ ! -f ".substrate/checks.d/$cb" ]; then
            warn "repo check $cb not vendored — it does NOT run; run: substrate update --apply"
        elif ! cmp -s "$c" ".substrate/checks.d/$cb"; then
            warn "repo check $cb drifted from its vendored copy — run: substrate update --apply"
        else
            success "repo check $cb vendored and current"
        fi
    done

    local engine_mode="${SUBSTRATE_ENGINE:-auto}" engine_bin="${SUBSTRATE_ENGINE_BIN:-}" engine_version=""
    if [ -z "$engine_bin" ]; then
        engine_bin=$(command -v substrate-engine 2>/dev/null) || engine_bin=""
    fi
    if [ -n "$engine_bin" ] && [ -x "$engine_bin" ]; then
        engine_version=$(timeout 5 "$engine_bin" version 2>/dev/null) || engine_version=""
    fi
    case "$engine_mode" in
        bash)
            info "engine: SUBSTRATE_ENGINE=bash — hooks run the vendored bash leg" ;;
        go)
            if [ -n "$engine_version" ]; then
                success "engine: go leg forced — $engine_bin ($engine_version)"
            else
                warn "engine: SUBSTRATE_ENGINE=go but no usable binary (${SUBSTRATE_ENGINE_BIN:-substrate-engine not on PATH}) — every ported hook exits 2"
            fi ;;
        auto)
            if [ -n "$engine_version" ]; then
                success "engine: auto resolves to go — $engine_bin ($engine_version)"
            else
                info "engine: auto falls back to bash — no substrate-engine binary (build it with: just engine)"
            fi ;;
        *)
            warn "engine: SUBSTRATE_ENGINE=$engine_mode is not auto|go|bash — hooks run the bash leg" ;;
    esac
    [ -z "${SUBSTRATE_ENGINE_SKIP:-}" ] \
        || info "engine: SUBSTRATE_ENGINE_SKIP keeps these hooks on bash: $SUBSTRATE_ENGINE_SKIP"

    local pin_version pin_sha bin_sha
    if [ ! -f .substrate/engine.json ]; then
        warn "engine pin: .substrate/engine.json missing — run: substrate update --apply"
    elif ! jq -e '(keys == ["binary_sha256", "version"]) and (.version|type=="string") and (.binary_sha256|test("^[0-9a-f]{64}$"))' \
            .substrate/engine.json >/dev/null 2>&1; then
        warn "engine pin: .substrate/engine.json is malformed — run: substrate engine pin"
    else
        pin_version=$(jq -r '.version' .substrate/engine.json)
        pin_sha=$(jq -r '.binary_sha256' .substrate/engine.json)
        if [ -z "$engine_bin" ]; then
            success "engine pin: $pin_version pinned (sha256 ${pin_sha:0:12}) — no local engine to attest"
        else
            case "$engine_version" in
                0.0.0-*)
                    warn "engine pin: dev build $engine_version not attested — build with: just engine (stamped)" ;;
                *)
                    if [ -n "${SUBSTRATE_ENGINE_BIN:-}" ]; then
                        warn "engine pin: SUBSTRATE_ENGINE_BIN override not attested — pin covers the vendored install only"
                    else
                        bin_sha=$(sha256sum "$engine_bin" 2>/dev/null | cut -d' ' -f1)
                        if [ "$pin_sha" = "$bin_sha" ]; then
                            success "engine pin: $engine_version attested (sha256 ${bin_sha:0:12})"
                        else
                            die "engine pin: $engine_bin sha256 ${bin_sha:0:12} does not match .substrate/engine.json (${pin_sha:0:12})"
                        fi
                    fi ;;
            esac
        fi
    fi

    if [ -d .jj ]; then
        local trunk configured bookmarks remotes
        trunk="${SUBSTRATE_JJ_TRUNK:-main}"
        configured=$(jj config get experimental-advance-branches.enabled-branches 2>/dev/null) || configured=""
        if [[ "$configured" == *"$trunk"* ]]; then
            success "jj trunk auto-advance configured ($trunk)"
        else
            warn "jj trunk auto-advance does not include configured trunk $trunk — rerun init"
        fi
        bookmarks=$(jj bookmark list 2>/dev/null) || bookmarks=""
        if printf '%s\n' "$bookmarks" | grep -q "^$trunk:"; then
            success "jj local trunk bookmark exists ($trunk)"
        else
            warn "jj local trunk bookmark missing ($trunk) — create it after the first commit"
        fi
        remotes=$(jj bookmark list --all-remotes 2>/dev/null) || remotes=""
        if printf '%s\n' "$remotes" | grep -q "^$trunk@origin:"; then
            success "jj trunk tracks origin ($trunk@origin)"
        else
            warn "jj trunk tracking is missing ($trunk@origin)"
        fi
        if grep -q 'enforce-jj.sh' .claude/settings.json 2>/dev/null; then
            success "jj workflow hooks wired"
        else
            warn "jj repo but enforce-jj not in .claude/settings.json — rerun init"
        fi
        [ -f docs/jj-workflow.md ] || warn "docs/jj-workflow.md missing — rerun init"
    fi

    local p d bin hint
    for p in "${profiles[@]}"; do
        d=$(profile_dir "$p") || { warn "profile $p not found"; continue; }
        while IFS=$'\t' read -r bin hint; do
            [ -n "$bin" ] || continue
            if command -v "$bin" >/dev/null 2>&1; then
                success "$p: $bin present"
            else
                warn "$p: $bin MISSING — $hint"
            fi
        done < <(jq -r '(.toolchain // [])[] | "\(.bin)\t\(.hint)"' "$d/profile.json")
    done
    for bin in jq ast-grep bunx; do
        if command -v "$bin" >/dev/null 2>&1; then
            success "core: $bin present"
        else
            warn "core: $bin missing (ast-grep falls back to bunx; bunx needs bun)"
        fi
    done
    local jq_path jq_id
    if jq_path=$(command -v jq); then
        jq_id=$("$jq_path" --version 2>/dev/null) || jq_id=""
        case "$jq_id" in
            jq-1.7*) success "core: jq identity $jq_id ($jq_path)" ;;
            *) warn "core: jq at $jq_path reports '${jq_id:-no version}' — every gate artifact is jq-1.7 serialization; a jaq/gojq/1.8 shim changes those bytes: install jq 1.7" ;;
        esac
    fi
    local pkg
    for bin in ast-grep jscpd; do
        case "$bin" in
            ast-grep) pkg="@ast-grep/cli" ;;
            *) pkg="$bin" ;;
        esac
        if command -v "$bin" >/dev/null 2>&1; then
            success "$bin: local binary (offline-safe)"
        else
            warn "$bin: bunx fallback — gate fetches from npm on a cold cache (breaks offline); install with: bun install -g $pkg"
        fi
    done
    info "kit root $KIT_ROOT"
    info "kit $(cat "$KIT_ROOT/VERSION"), vendored $(cat .substrate/VERSION 2>/dev/null || echo none)"
}
