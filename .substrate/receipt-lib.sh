#!/usr/bin/env bash
# Exact-state gate receipts shared by checkpoints and push guards.
# shellcheck source=./engine-shim.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/engine-shim.sh" 2>/dev/null || true

substrate_metadata_dir() {
    local git_dir
    if git_dir=$(git rev-parse --git-common-dir 2>/dev/null); then
        case "$git_dir" in
            /*) printf '%s\n' "$git_dir" ;;
            *) printf '%s\n' "$REPO_ROOT/$git_dir" ;;
        esac
    elif [ -d "$REPO_ROOT/.jj" ]; then
        printf '%s\n' "$REPO_ROOT/.jj"
    else
        return 1
    fi
}

substrate_safe_path() {
    case "$1" in
        ''|/*|..|../*|*/../*|*/..|-*) return 1 ;;
    esac
    return 0
}

current_gate_vcs() {
    if [ -e .jj ] && command -v jj >/dev/null 2>&1; then printf 'jj\n'; else printf 'git\n'; fi
}

current_gate_revision() {
    if [ "$(current_gate_vcs)" = jj ]; then
        jj log -r @- --no-graph -T 'commit_id' 2>/dev/null
    else
        git rev-parse HEAD 2>/dev/null
    fi
}

working_copy_clean() {
    local pending
    if [ "$(current_gate_vcs)" = jj ]; then
        pending=$(jj diff --name-only 2>/dev/null) || return 1
    else
        pending=$(git status --porcelain=v1 --untracked-files=all 2>/dev/null) || return 1
    fi
    [ -z "$pending" ]
}

hash_file_state() {
    local path="$1"
    if [ -f "$path" ] && [ ! -L "$path" ]; then
        sha256sum "$path" | cut -d ' ' -f 1
    elif [ -L "$path" ]; then
        printf 'symlink:%s\n' "$(readlink "$path" 2>/dev/null || printf unreadable)"
    else
        printf 'missing\n'
    fi
}

engine_state_hash() {
    local records path rel mode digest hash
    [ -d .substrate ] || return 1
    records=$(mktemp) || return 1
    while IFS= read -r -d '' path; do
        rel=${path#./}
        if [ -L "$path" ]; then
            printf '%s\tsymlink\t%s\n' "$rel" "$(readlink "$path" 2>/dev/null || printf unreadable)" >> "$records" \
                || { rm -f "$records"; return 1; }
        else
            mode=$(stat -c '%a' "$path") || { rm -f "$records"; return 1; }
            hash=$(sha256sum "$path" | cut -d ' ' -f 1) || { rm -f "$records"; return 1; }
            printf '%s\t%s\t%s\n' "$rel" "$mode" "$hash" >> "$records" \
                || { rm -f "$records"; return 1; }
        fi
    done < <(find .substrate \( -type f -o -type l \) -print0 | LC_ALL=C sort -z)
    [ -s "$records" ] || { rm -f "$records"; return 1; }
    digest=$(sha256sum "$records" | cut -d ' ' -f 1) || { rm -f "$records"; return 1; }
    rm -f "$records"
    printf '%s\n' "$digest"
}

toolchain_state_hash() {
    local raw list records bin path real mode profile profile_json digest hash package_dir package_hash
    raw=$(mktemp) || return 1
    list=$(mktemp) || { rm -f "$raw"; return 1; }
    records=$(mktemp) || { rm -f "$raw" "$list"; return 1; }
    printf '%s\n' bash git jq yq bun bunx ast-grep jscpd gitleaks actionlint > "$raw"
    [ "$(current_gate_vcs)" != jj ] || printf 'jj\n' >> "$raw"
    while IFS= read -r profile; do
        profile_json=".substrate/profiles/$profile/profile.json"
        [ -f "$profile_json" ] || continue
        jq -r '.toolchain[]?.bin // empty' "$profile_json" >> "$raw" 2>/dev/null \
            || { rm -f "$raw" "$list" "$records"; return 1; }
    done < <(jq -r '.profiles[]' substrate.json 2>/dev/null)
    LC_ALL=C sort -u "$raw" > "$list" || { rm -f "$raw" "$list" "$records"; return 1; }
    while IFS= read -r bin; do
        [ -n "$bin" ] || continue
        path=$(command -v "$bin" 2>/dev/null) || { printf '%s\tmissing\n' "$bin" >> "$records"; continue; }
        real=$(readlink -f "$path" 2>/dev/null) || real=$path
        if [ -f "$real" ]; then
            mode=$(stat -c '%a' "$real") || { rm -f "$raw" "$list" "$records"; return 1; }
            hash=$(sha256sum "$real" | cut -d ' ' -f 1) || { rm -f "$raw" "$list" "$records"; return 1; }
            package_dir=$(dirname "$real")
            package_hash=none
            while [ "$package_dir" != / ] && [ "${#package_dir}" -gt 1 ]; do
                if [ -f "$package_dir/package.json" ]; then
                    package_hash=$(sha256sum "$package_dir/package.json" | cut -d ' ' -f 1) || {
                        rm -f "$raw" "$list" "$records"
                        return 1
                    }
                    break
                fi
                package_dir=$(dirname "$package_dir")
            done
            printf '%s\t%s\t%s\t%s\n' "$bin" "$mode" "$hash" "$package_hash" >> "$records" \
                || { rm -f "$raw" "$list" "$records"; return 1; }
        else
            printf '%s\t%s\n' "$bin" "$path" >> "$records" \
                || { rm -f "$raw" "$list" "$records"; return 1; }
        fi
    done < "$list"
    digest=$(sha256sum "$records" | cut -d ' ' -f 1) \
        || { rm -f "$raw" "$list" "$records"; return 1; }
    rm -f "$raw" "$list" "$records"
    printf '%s\n' "$digest"
}

repository_state_hash() {
    local paths records path mode digest hash
    paths=$(mktemp) || return 1
    records=$(mktemp) || { rm -f "$paths"; return 1; }
    if [ "$(current_gate_vcs)" = jj ]; then
        jj file list -T 'path ++ "\0"' > "$paths" 2>/dev/null \
            || { rm -f "$paths" "$records"; return 1; }
    else
        git ls-files -z --cached > "$paths" || { rm -f "$paths" "$records"; return 1; }
    fi
    while IFS= read -r -d '' path; do
        if [ -L "$path" ]; then
            printf '%q\tsymlink\t%q\n' "$path" "$(readlink "$path" 2>/dev/null || printf unreadable)" >> "$records"
        elif [ -f "$path" ]; then
            mode=$(stat -c '%a' "$path") || { rm -f "$paths" "$records"; return 1; }
            hash=$(sha256sum "$path" | cut -d ' ' -f 1) || { rm -f "$paths" "$records"; return 1; }
            printf '%q\t%s\t%s\n' "$path" "$mode" "$hash" >> "$records"
        else
            printf '%q\tmissing\n' "$path" >> "$records"
        fi
    done < "$paths"
    digest=$(sha256sum "$records" | cut -d ' ' -f 1) || { rm -f "$paths" "$records"; return 1; }
    rm -f "$paths" "$records"
    printf '%s\n' "$digest"
}

configuration_state_hash() {
    local raw paths records profile profile_json path mode digest hash
    raw=$(mktemp) || return 1
    paths=$(mktemp) || { rm -f "$raw"; return 1; }
    records=$(mktemp) || { rm -f "$raw" "$paths"; return 1; }
    printf '%s\0' substrate.json substrate-baseline.json .gitleaks.toml .gitleaksignore \
        .jscpd.json .jscpdrc .shellcheckrc > "$raw"
    while IFS= read -r profile; do
        profile_json=".substrate/profiles/$profile/profile.json"
        [ -f "$profile_json" ] || continue
        while IFS= read -r path; do
            [ -n "$path" ] && printf '%s\0' "$path" >> "$raw"
        done < <(jq -r '.templates[]?.dest // empty' "$profile_json" 2>/dev/null)
    done < <(jq -r '.profiles[]' substrate.json 2>/dev/null)
    find . \( -path ./.git -o -path ./.jj -o -path ./.substrate -o -name node_modules \) -prune -o \
        \( -type f -o -type l \) \( -name .gitleaks.toml -o -name .gitleaksignore \
        -o -name .jscpd.json -o -name .jscpdrc -o -name .shellcheckrc -o -name ruff.toml \
        -o -name .ruff.toml -o -name pyproject.toml -o -name setup.cfg -o -name .importlinter \
        -o -name .golangci.yml -o -name .golangci.yaml -o -name .stylua.toml \
        -o -name .luacheckrc -o -name .sqlfluff -o -name .tflint.hcl \
        -o -name tsconfig.json -o -name .dependency-cruiser.cjs -o -name svelte.config.js \
        -o -name dbt_project.yml -o -name go.mod -o -name go.sum -o -name package.json \
        -o -name bun.lock -o -name bun.lockb -o -name package-lock.json \
        -o -name pnpm-lock.yaml -o -name yarn.lock -o -name compile_commands.json \
        -o -name .clang-tidy -o -name .terraform.lock.hcl -o -name actionlint.yaml \
        -o -name actionlint.yml \) -print0 >> "$raw"
    LC_ALL=C sort -zu "$raw" > "$paths" || { rm -f "$raw" "$paths" "$records"; return 1; }
    while IFS= read -r -d '' path; do
        if [ -L "$path" ]; then
            printf '%q\tsymlink\t%q\n' "$path" "$(readlink "$path" 2>/dev/null || printf unreadable)" >> "$records"
        elif [ -f "$path" ]; then
            mode=$(stat -c '%a' "$path") || { rm -f "$raw" "$paths" "$records"; return 1; }
            hash=$(sha256sum "$path" | cut -d ' ' -f 1) || { rm -f "$raw" "$paths" "$records"; return 1; }
            printf '%q\t%s\t%s\n' "$path" "$mode" "$hash" >> "$records"
        else
            printf '%q\tmissing\n' "$path" >> "$records"
        fi
    done < "$paths"
    digest=$(sha256sum "$records" | cut -d ' ' -f 1) \
        || { rm -f "$raw" "$paths" "$records"; return 1; }
    rm -f "$raw" "$paths" "$records"
    printf '%s\n' "$digest"
}

external_gate_state_hash() {
    local sdk
    sdk="${BUN_INSTALL:-$HOME/.bun}/install/global/node_modules/@oh-my-pi/pi-coding-agent/dist/types/index.d.ts"
    {
        printf 'omp-sdk\t%s\t%s\n' "$sdk" "$(hash_file_state "$sdk")"
        printf 'environment\tHOME=%s\tBUN_INSTALL=%s\tCI=%s\tSUBSTRATE_FILE_LIST=%s\tLANG=%s\tLC_ALL=%s\n' \
            "${HOME:-}" "${BUN_INSTALL:-}" "${CI:-}" "${SUBSTRATE_FILE_LIST:-}" "${LANG:-}" "${LC_ALL:-}"
    } | sha256sum | cut -d ' ' -f 1
}

refs_state_hash() {
    local records digest
    records=$(mktemp) || return 1
    if git rev-parse --git-dir >/dev/null 2>&1; then
        {
            git for-each-ref --format='%(refname) %(objectname)' refs/heads refs/tags refs/remotes
            git symbolic-ref -q HEAD 2>/dev/null || true
        } | LC_ALL=C sort -u >> "$records" || { rm -f "$records"; return 1; }
    fi
    if [ "$(current_gate_vcs)" = jj ]; then
        jj bookmark list --all-remotes --sort name --color never --no-pager >> "$records" 2>/dev/null \
            || { rm -f "$records"; return 1; }
    fi
    digest=$(sha256sum "$records" | cut -d ' ' -f 1) || { rm -f "$records"; return 1; }
    rm -f "$records"
    printf '%s\n' "$digest"
}

gate_state_json() {
    local revision refs_hash repository_hash engine_hash toolchain_hash config_hash external_hash
    [ -z "${SUBSTRATE_FILE_LIST:-}" ] || return 1
    [ "$(jq -r '(.contracts // []) | length' substrate.json 2>/dev/null)" -eq 0 ] || return 1
    working_copy_clean || return 1
    revision=$(current_gate_revision) || return 1
    refs_hash=$(refs_state_hash) || return 1
    repository_hash=$(repository_state_hash) || return 1
    engine_hash=$(engine_state_hash) || return 1
    toolchain_hash=$(toolchain_state_hash) || return 1
    config_hash=$(configuration_state_hash) || return 1
    external_hash=$(external_gate_state_hash) || return 1
    jq -cnS --arg revision "$revision" --arg refsHash "$refs_hash" \
        --arg repositoryHash "$repository_hash" --arg engineHash "$engine_hash" \
        --arg toolchainHash "$toolchain_hash" --arg configurationHash "$config_hash" \
        --arg externalHash "$external_hash" \
        '{revision:$revision,refsHash:$refsHash,repositoryHash:$repositoryHash,engineHash:$engineHash,toolchainHash:$toolchainHash,configurationHash:$configurationHash,externalHash:$externalHash}'
}

gate_state_fingerprint() {
    gate_state_json | sha256sum | cut -d ' ' -f 1
}

gate_receipt_path() {
    local metadata
    metadata=$(substrate_metadata_dir) || return 1
    printf '%s/substrate/gate-receipt.json\n' "$metadata"
}

gate_receipt_matches_v1() {
    local path fingerprint
    path=$(gate_receipt_path) || return 1
    [ -f "$path" ] && jq -e '.status == "passed" and .reusable == true and (.fingerprint | type == "string")' "$path" >/dev/null 2>&1 \
        || return 1
    fingerprint=$(gate_state_fingerprint) || return 1
    [ "$(jq -r '.fingerprint' "$path")" = "$fingerprint" ]
}

write_gate_receipt_v1() {
    local source="$1" commit="$2" vcs="$3" session="${4:-}" path dir state fingerprint receipt staged candidate current reusable
    current=$(current_gate_revision) || return 1
    [ "$current" = "$commit" ] || return 1
    state=null
    fingerprint=""
    reusable=false
    if candidate=$(gate_state_json); then
        state=$candidate
        fingerprint=$(printf '%s\n' "$state" | sha256sum | cut -d ' ' -f 1) || return 1
        reusable=true
    fi
    path=$(gate_receipt_path) || return 1
    dir=$(dirname "$path")
    mkdir -p "$dir" || return 1
    receipt=$(jq -cn --arg source "$source" --arg commit "$commit" --arg vcs "$vcs" \
        --arg session "$session" --arg fingerprint "$fingerprint" --arg reusable "$reusable" \
        --arg engineVersion "$(cat .substrate/VERSION 2>/dev/null)" \
        --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson state "$state" \
        '{commit:$commit,vcs:$vcs,source:$source,session:(if $session == "" then null else $session end),fingerprint:(if $fingerprint == "" then null else $fingerprint end),reusable:($reusable == "true"),engineVersion:$engineVersion,state:$state,at:$at,status:"passed"}') \
        || return 1
    staged=$(mktemp "$path.XXXXXX") || return 1
    if printf '%s\n' "$receipt" > "$staged" && chmod 600 "$staged" && mv -f "$staged" "$path"; then
        printf '%s\n' "$receipt"
        return 0
    fi
    rm -f "$staged"
    return 1
}

gate_receipt_matches() {
    declare -F _substrate_engine_delegate >/dev/null 2>&1 || { gate_receipt_matches_v1; return; }
    _substrate_engine_delegate receipt gate_receipt_matches_v1 receipt matches --
}

write_gate_receipt() {
    declare -F _substrate_engine_delegate >/dev/null 2>&1 || { write_gate_receipt_v1 "$@"; return; }
    _substrate_engine_delegate receipt write_gate_receipt_v1 receipt write -- "$@"
}
