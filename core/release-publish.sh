#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
forge="$here/forge.sh"

tag="${RELEASE_TAG:?RELEASE_TAG is required}"
prerelease="${RELEASE_PRERELEASE:?RELEASE_PRERELEASE is required}"
base="${RELEASE_BASE:?RELEASE_BASE is required}"
nightly_base="${RELEASE_NIGHTLY_BASE:-$base}"
notes="${RELEASE_NOTES:-notes.md}"
keep_days="${RELEASE_KEEP_DAYS:-14}"
target="${1:-}"

[ -f "$notes" ] || { printf '::error::release notes %s not found\n' "$notes" >&2; exit 1; }

shopt -s nullglob
assets=(substrate_*.tar.gz SHA256SUMS)
shopt -u nullglob
[ "${#assets[@]}" -gt 0 ] || { printf '::error::no release artifacts to upload\n' >&2; exit 1; }

id=$("$forge" create-release "$tag" "$tag" "$prerelease" "$notes" "$target")
for asset in "${assets[@]}"; do
    "$forge" upload-asset "$id" "$asset"
done

"$forge" prune-prereleases "v${base}-nightly." "$keep_days"
[ "$nightly_base" = "$base" ] \
    || "$forge" prune-prereleases "v${nightly_base}-nightly." "$keep_days"
