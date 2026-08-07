# Shared setup for the self-built dual-leg Go engine oracles (amendments
# A1/A25): a scratch HOME, the fake OMP SDK + PATH shim that
# external_gate_state_hash inspects, and the engine build itself. Sourced
# only; callers set KIT_ROOT first. engine_build prints the built binary
# path on stdout — callers capture it, e.g. `BIN=$(engine_build ...) || exit 1`.

engine_fixture_home() {
    T=$(mktemp -d)
    trap 'rm -rf "$T"' EXIT
    export HOME="$T/home"
    mkdir -p "$HOME"
}

engine_fixture_sdk() {
    local sdk_dir="$HOME/.bun/install/global/node_modules/@oh-my-pi/pi-coding-agent/dist/types"
    mkdir -p "$sdk_dir" "$T/fake-bin"
    export BUN_INSTALL="$HOME/.bun"
    printf 'sdk-v1\n' > "$sdk_dir/index.d.ts"
    cat > "$T/fake-bin/actionlint" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod +x "$T/fake-bin/actionlint"
    export PATH="$T/fake-bin:$PATH"
}

engine_build() {
    local fail_fn="$1" label="$2" version="${3:-}" dir
    dir=$(mktemp -d) || "$fail_fn" "$label build dir"
    if [ -n "$version" ]; then
        ( cd "$KIT_ROOT" && go build -trimpath -buildvcs=false -ldflags "-X main.version=$version" -o "$dir/substrate-engine" ./cmd/substrate-engine ) \
            || "$fail_fn" "$label engine build failed"
    else
        ( cd "$KIT_ROOT" && go build -trimpath -buildvcs=false -o "$dir/substrate-engine" ./cmd/substrate-engine ) \
            || "$fail_fn" "$label engine build failed"
    fi
    printf '%s\n' "$dir/substrate-engine"
}
