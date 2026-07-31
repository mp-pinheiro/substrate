#!/usr/bin/env bash
# Runs clang-tidy (bugprone + performance, pinned) over claimed C/C++ files
# listed in the repo compile database; without one the check is inactive.
set -uo pipefail
# shellcheck source=../gate-lib.sh
source "$SUBSTRATE_DIR/gate-lib.sh"

compile_db="$REPO_ROOT/compile_commands.json"
if [ ! -f "$compile_db" ]; then
    warn "no compile_commands.json at repo root — clang-tidy inactive (export it via CMAKE_EXPORT_COMPILE_COMMANDS=ON or bear)"
    exit 0
fi
jq -e . "$compile_db" >/dev/null 2>&1 || die_infra "compile_commands.json is not valid JSON — regenerate it"

files=()
mapfile -t files < <(profile_files cpp cpp)

[ ${#files[@]} -gt 0 ] || exit 0

require_bin_ci clang-tidy "profile toolchain — see profiles/cpp/profile.json" || exit 0

# gate:allow-comment Only files the compile database can build are lintable;
# entries resolve file against directory, both possibly relative to the repo
# root — the db location clang-tidy -p is pointed at.
declare -A in_db=()
while IFS=$'\t' read -r dir file; do
    [ -n "$file" ] || continue
    case "$file" in
        /*) p="$file" ;;
        *)
            case "$dir" in
                /*) p="$dir/$file" ;;
                *) p="$REPO_ROOT/$dir/$file" ;;
            esac
            ;;
    esac
    in_db["$(realpath -m "$p")"]=1
done < <(jq -r '.[] | [(.directory // "."), .file] | @tsv' "$compile_db")

targets=()
for f in "${files[@]}"; do
    [ -n "${in_db[$(realpath -m "$REPO_ROOT/$f")]:-}" ] && targets+=("$f")
done
if [ ${#targets[@]} -eq 0 ]; then
    warn "no claimed C/C++ files appear in compile_commands.json — nothing to lint"
    exit 0
fi

# gate:allow-comment clang-tidy does not resolve a relative "directory"
# against the db location; feed it a normalized copy with directories
# absolutized against the repo root so fixture and consumer dbs both work.
norm_dir=$(mktemp -d)
trap 'rm -rf "$norm_dir"' EXIT
jq --arg root "$REPO_ROOT" \
    'map(.directory = ((.directory // ".") | if startswith("/") then . else $root + "/" + . end))' \
    "$compile_db" > "$norm_dir/compile_commands.json" \
    || die_infra "failed to normalize compile_commands.json"

out=$(clang-tidy -p "$norm_dir" --quiet --config='{}' \
    '--checks=-*,bugprone-*,performance-*' \
    '--warnings-as-errors=bugprone-*,performance-*' \
    "${targets[@]}" 2>&1)
rc=$?
if grep -qF 'Compile command not found' <<< "$out"; then
    printf '%s\n' "$out"
    die_infra "clang-tidy could not match a target to the compile database — cannot pass blind"
fi
if [ "$rc" -eq 0 ]; then
    exit 0
fi
printf '%s\n' "$out"
if grep -qE '\[(bugprone|performance)-' <<< "$out"; then
    exit 1
fi
die_infra "clang-tidy failed (rc=$rc) without findings — fix the compile database or the invocation"
