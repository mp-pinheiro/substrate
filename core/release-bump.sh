#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
requested="${1:-}"
current=$(cat "$root/VERSION")
if [[ ! "$current" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    printf 'release-bump: VERSION must be X.Y.Z, found %s\n' "$current" >&2
    exit 2
fi
major=${BASH_REMATCH[1]}
minor=${BASH_REMATCH[2]}
patch=${BASH_REMATCH[3]}
case "$requested" in
    major) next="$((major + 1)).0.0" ;;
    minor) next="$major.$((minor + 1)).0" ;;
    patch) next="$major.$minor.$((patch + 1))" ;;
    [0-9]*.[0-9]*.[0-9]*) next="$requested" ;;
    *) printf 'usage: just bump major|minor|patch|X.Y.Z\n' >&2; exit 2 ;;
esac
if [[ ! "$next" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    printf 'release-bump: target must be X.Y.Z, found %s\n' "$next" >&2
    exit 2
fi
next_major=${BASH_REMATCH[1]}
next_minor=${BASH_REMATCH[2]}
next_patch=${BASH_REMATCH[3]}
if (( next_major < major ||
      (next_major == major && next_minor < minor) ||
      (next_major == major && next_minor == minor && next_patch <= patch) )); then
    printf 'release-bump: target %s must be greater than %s\n' "$next" "$current" >&2
    exit 2
fi
if git -C "$root" rev-parse -q --verify "refs/tags/v$next" >/dev/null; then
    printf 'release-bump: tag v%s already exists\n' "$next" >&2
    exit 2
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp "$root/VERSION" "$work/VERSION.old"
cp "$root/engine.json" "$work/engine.json.old"
cp -a "$root/.substrate" "$work/substrate.old"
printf '%s\n' "$next" > "$work/VERSION"
(
    cd "$root"
    GOTOOLCHAIN=go1.27.1 CGO_ENABLED=1 go build -trimpath -buildvcs=false \
        -ldflags "-X main.version=$next" -o "$work/substrate-engine" ./cmd/substrate-engine
)
"$work/substrate-engine" pin emit > "$work/engine.json"
mv "$work/VERSION" "$root/VERSION"
mv "$work/engine.json" "$root/engine.json"
if ! PATH="$work:$PATH" SUBSTRATE_ENGINE_BIN="$work/substrate-engine" SUBSTRATE_NO_USER_HARNESS=1 \
    "$root/bin/substrate" update --apply --from-worktree; then
    mv "$work/VERSION.old" "$root/VERSION"
    mv "$work/engine.json.old" "$root/engine.json"
    rm -rf "$root/.substrate"
    mv "$work/substrate.old" "$root/.substrate"
    exit 1
fi
mkdir -p "$root/build"
cp "$work/substrate-engine" "$root/build/substrate-engine"
printf 'release-bump: %s -> %s\n' "$current" "$next"
