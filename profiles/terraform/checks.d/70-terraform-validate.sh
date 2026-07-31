#!/usr/bin/env bash
# Validates terraform configs (init -backend=false, then validate) in a temp
# copy so provider downloads and lockfile writes never dirty the tree.
set -uo pipefail
# shellcheck source=../gate-lib.sh
source "$SUBSTRATE_DIR/gate-lib.sh"

declare -a copy_files=()
declare -A tf_dirs=()
while IFS= read -r f; do
    case "$f" in
        *.tf)
            copy_files+=("$f")
            case "$f" in
                */*) tf_dirs["${f%/*}"]=1 ;;
                *) tf_dirs["."]=1 ;;
            esac
            ;;
        *.terraform.lock.hcl) copy_files+=("$f") ;;
    esac
done < <(profile_files terraform)
[ ${#tf_dirs[@]} -gt 0 ] || exit 0

require_bin_ci terraform "profile toolchain — see profiles/terraform/profile.json" || exit 0

tmpdir=$(mktemp -d) || die_infra "mktemp failed — cannot build validate sandbox"
trap 'rm -rf "$tmpdir"' EXIT
for f in "${copy_files[@]}"; do
    case "$f" in
        */*) mkdir -p "$tmpdir/${f%/*}" ;;
    esac
    cp "$REPO_ROOT/$f" "$tmpdir/$f" || die_infra "copying $f into validate sandbox failed"
done

# empty CLI config pins verdicts against user-global .terraformrc mirrors/caches
: > "$tmpdir/.terraformrc-pinned"
export TF_CLI_CONFIG_FILE="$tmpdir/.terraformrc-pinned"
export TF_IN_AUTOMATION=1

findings=""
while IFS= read -r dir; do
    out=$(terraform -chdir="$tmpdir/$dir" init -backend=false -input=false -no-color 2>&1) \
        || die_infra "terraform init -backend=false failed in $dir — provider/module resolution is broken, validate cannot run: $out"
    out=$(terraform -chdir="$tmpdir/$dir" validate -no-color 2>&1)
    rc=$?
    case "$rc" in
        0) ;;
        1) findings+="$dir:"$'\n'"$out"$'\n' ;;
        *) die_infra "terraform validate failed in $dir (rc=$rc): $out" ;;
    esac
done < <(printf '%s\n' "${!tf_dirs[@]}" | sort)

if [ -n "$findings" ]; then
    printf '%s' "$findings"
    printf 'terraform validate — fix the configuration errors above (validate runs with -backend=false; repos declaring providers pay provider download time here)\n'
    exit 1
fi
exit 0
