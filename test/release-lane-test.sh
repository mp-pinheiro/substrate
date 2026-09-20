#!/usr/bin/env bash
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'release-lane-test FAIL: %s\n' "$1" >&2; exit 1; }
ok() { printf '\033[0;32m[ok]\033[0m release-lane-test: %s\n' "$*"; }

T=$(mktemp -d) || fail "scratch dir"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/api" || fail "scratch layout"

cat > "$T/bin/curl" <<'SHIM'
#!/usr/bin/env bash
url=""
for a in "$@"; do case "$a" in https://*) url=$a;; esac; done
if [ -f "$API_DIR/force-code" ]; then
    printf '{"message":"stubbed failure"}\n%s' "$(cat "$API_DIR/force-code")"
    exit 0
fi
method=GET
prev=""
for a in "$@"; do [ "$prev" = -X ] && method=$a; prev=$a; done
case "$url" in
    */push_mirrors-sync) printf '204'; exit 0 ;;
esac
if [ "$method" = POST ] && case "$url" in */git/refs) true;; *) false;; esac; then
    code=$(cat "$API_DIR/tag-code" 2>/dev/null || echo 201)
    printf '{"message":"stubbed ref post"}\n%s' "$code"
    exit 0
fi
case "$url" in
    */git/ref/tags/*) f="$API_DIR/ref-${url##*/}" ;;
    */git/tags/*)     f="$API_DIR/obj-${url##*/}" ;;
    */commits/*)      f="$API_DIR/commit-${url##*/}" ;;
    *)                f="" ;;
esac
if [ -n "$f" ] && [ -f "$f" ]; then
    printf '%s\n200' "$(cat "$f")"
else
    printf '{"message":"Not Found"}\n404'
fi
SHIM
chmod +x "$T/bin/curl" || fail "shim"
export PATH="$T/bin:$PATH" API_DIR="$T/api"

repo="$T/repo"
mkdir -p "$repo" || fail "scratch repo"
cd "$repo" || fail "cannot enter the scratch repo"
git init -q -b main . || fail "git init"
git config user.email t@t && git config user.name t
echo 0.2.0 > VERSION
git add VERSION || fail "stage VERSION"
git commit -qm init || fail "seed commit"
head_sha=$(git rev-parse HEAD)

identity() {
    : > "$T/out"
    env RELEASE_EVENT="$1" RELEASE_CHANNEL="${2:-}" RELEASE_HEAD_SHA="${3:-$head_sha}" \
        RELEASE_DATE=20260101 RELEASE_MIRROR_TOKEN=stub RELEASE_OUTPUT="$T/out" \
        bash "$KIT_ROOT/core/release-identity.sh" > "$T/ann" 2>&1
}

field() { sed -n "s/^$1=//p" "$T/out"; }
ann() { cat "$T/ann"; }

identity workflow_dispatch "" || fail "stable identity exited $?: $(ann)"
[ "$(field version)" = 0.2.0 ] || fail "stable version: $(cat "$T/out")"
[ "$(field channel)" = release ] || fail "stable channel: $(cat "$T/out")"
[ "$(field prerelease)" = false ] || fail "stable prerelease: $(cat "$T/out")"
[ "$(field skip)" = false ] || fail "stable skip: $(cat "$T/out")"
ok "first stable cut resolves v0.2.0 on the release channel"

identity schedule "" || fail "nightly identity exited $?: $(ann)"
[ "$(field version)" = 0.2.0-nightly.20260101 ] || fail "nightly version: $(cat "$T/out")"
[ "$(field prerelease)" = true ] || fail "nightly prerelease: $(cat "$T/out")"
ok "nightly with no stable tag keeps the current base"

git tag -a v0.2.0 -m release || fail "annotated tag"
first_sha=$head_sha
identity schedule "" || fail "post-stable nightly exited $?: $(ann)"
[ "$(field version)" = 0.3.0-nightly.20260101 ] \
    || fail "nightly must sort above the published stable: $(cat "$T/out")"
ok "nightly bumps past a published stable so semver keeps ordering"

git commit -q --allow-empty -m next || fail "second commit"
head_sha=$(git rev-parse HEAD)

identity workflow_dispatch "" && fail "re-cutting a published stable from a new revision must be refused"
ann | grep -q 'already points at' || fail "refusal must name the collision: $(ann)"
ok "re-cutting a published stable from a new revision is refused"

identity workflow_dispatch "" "$first_sha" || fail "resuming the same revision must be allowed: $(ann)"
[ "$(field skip)" = false ] || fail "resume must not skip: $(cat "$T/out")"
ann | grep -q 'resuming publication' || fail "resume must be announced: $(ann)"
ok "re-running at the published revision resumes instead of failing"

git tag -a v0.3.0-nightly.20260101 -m nightly || fail "nightly tag"
git commit -q --allow-empty -m third || fail "third commit"
head_sha=$(git rev-parse HEAD)
identity schedule "" || fail "cron collision must not fail the run: $(ann)"
[ "$(field skip)" = true ] || fail "cron collision must skip: $(cat "$T/out")"
ann | grep -q 'nothing to cut' || fail "skip must be announced: $(ann)"
ok "cron re-hitting today's nightly skips instead of reding the run"

identity workflow_dispatch nightly && fail "manual re-dispatch of an existing nightly must be refused"
ok "manual re-dispatch of the same nightly is refused"

git tag -d v0.3.0-nightly.20260101 >/dev/null || fail "tag cleanup"
identity schedule "" || fail "clean cron exited $?: $(ann)"
[ "$(field skip)" = false ] || fail "a cron with no tag today must proceed: $(cat "$T/out")"
ok "cron with no tag for today proceeds to a fresh nightly"

mirror="$T/mirror"
mkdir -p "$mirror" || fail "mirror repo"
(cd "$mirror" && git init -q -b main . && git config user.email t@t && git config user.name t \
    && echo 0.2.0 > VERSION && git add VERSION && git commit -qm init) || fail "mirror seed"
mirror_commit=$(cd "$mirror" && git rev-parse HEAD)
printf '{"object":{"sha":"tagobject00000000000000000000000000000000","type":"tag"}}' \
    > "$T/api/ref-v0.2.0"
printf '{"object":{"sha":"%s","type":"commit"}}' "$mirror_commit" \
    > "$T/api/obj-tagobject00000000000000000000000000000000"
cd "$mirror" || fail "cannot enter the mirror repo"
identity workflow_dispatch "" "$mirror_commit" || fail "annotated deref via API failed: $(ann)"
ann | grep -q 'resuming publication' \
    || fail "an annotated tag from the API must compare by its commit, not its tag object: $(ann)"
identity workflow_dispatch "" tagobject00000000000000000000000000000000 \
    && fail "the tag object sha must not be mistaken for the released commit"
ok "annotated tags from the mirror API dereference to the commit, not the tag object"

echo 500 > "$T/api/force-code"
identity workflow_dispatch "" && fail "a 500 from the mirror must not be read as an absent tag"
ann | grep -q 'HTTP 500' || fail "the failure must name the status: $(ann)"
[ "$(ann | grep -c '^::error::')" = 1 ] \
    || fail "an outage must log one honest annotation, not a misleading follow-up: $(ann)"
echo 401 > "$T/api/force-code"
identity workflow_dispatch "" && fail "a 401 from the mirror must not be read as an absent tag"
rm -f "$T/api/force-code"
ok "a failing mirror lookup fails closed instead of disabling the clobber guard"

env RELEASE_EVENT=workflow_dispatch RELEASE_HEAD_SHA="$mirror_commit" RELEASE_DATE=20260101 \
    RELEASE_MIRROR_TOKEN= MIRROR_TOKEN= RELEASE_OUTPUT="$T/out" \
    bash "$KIT_ROOT/core/release-identity.sh" > "$T/ann" 2>&1 \
    && fail "a missing mirror token must not silently skip the collision check"
ann | grep -q 'no mirror token' || fail "the missing token must be named: $(ann)"
ok "a missing mirror token fails closed rather than publishing unchecked"


real_base=$(cat "$KIT_ROOT/VERSION") || fail "cannot read the kit VERSION"
real_head=$(cd "$KIT_ROOT" && git rev-parse HEAD) || fail "cannot resolve the kit HEAD"
printf '{"object":{"sha":"%s","type":"commit"}}' "$real_head" > "$T/api/ref-v$real_base"
IFS=. read -r rmaj rmin _ <<< "$real_base"
expect_nightly="${rmaj}.$((rmin + 1)).0-nightly.20260921"
cd "$KIT_ROOT" || fail "cannot enter the kit"
runner="$KIT_ROOT/core/release-identity.sh"
[ -x "$runner" ] || fail "core/release-identity.sh lost its exec bit — CI runs it directly, not via bash"
if [ -e "$KIT_ROOT/.substrate/release-identity.sh" ]; then
    [ -x "$KIT_ROOT/.substrate/release-identity.sh" ] \
        || fail ".substrate/release-identity.sh is not executable — the workflow's direct run would die on it"
    runner="$KIT_ROOT/.substrate/release-identity.sh"
fi
: > "$T/out"
env RELEASE_EVENT=schedule RELEASE_HEAD_SHA="$real_head" RELEASE_DATE=20260921 \
    RELEASE_MIRROR_TOKEN=stub RELEASE_OUTPUT="$T/out" \
    "$runner" > "$T/ann" 2>&1 \
    || fail "tomorrow's cron against the real VERSION exited $?: $(ann)"
[ "$(field version)" = "$expect_nightly" ] \
    || fail "real-repo cron must cut $expect_nightly, got: $(cat "$T/out")"
[ "$(field skip)" = false ] || fail "real-repo cron must not skip: $(cat "$T/out")"
[ "$(field prerelease)" = true ] || fail "real-repo cron must be a prerelease: $(cat "$T/out")"
rm -f "$T/api/ref-v$real_base"
ok "tomorrow's cron against the real VERSION and a published v$real_base cuts $expect_nightly"
cd "$repo" || fail "cannot re-enter the scratch repo"
: > VERSION
identity workflow_dispatch "" && fail "an empty VERSION must be refused, not published as v"
ann | grep -q 'missing or empty' || fail "empty VERSION must be named: $(ann)"
ok "an empty VERSION file is refused before anything is tagged"

mirror_tag() {
    : > "$T/ann"
    env RELEASE_TAG="$1" RELEASE_HEAD_SHA="$2" RELEASE_MIRROR_TOKEN=stub \
        RELEASE_MIRROR_WAITS="0 0" \
        "$KIT_ROOT/core/release-mirror-tag.sh" > "$T/ann" 2>&1
}

tag_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
printf '{"sha":"%s"}' "$tag_sha" > "$T/api/commit-$tag_sha"
echo 201 > "$T/api/tag-code"
mirror_tag v9.9.9 "$tag_sha" || fail "creating a fresh mirror tag exited $?: $(ann)"
ann | grep -q "created v9.9.9 on the mirror" || fail "creation must be announced: $(ann)"
ok "a fresh mirror tag is created at the released revision"

echo 422 > "$T/api/tag-code"
printf '{"object":{"sha":"tagobject11111111111111111111111111111111","type":"tag"}}' \
    > "$T/api/ref-v9.9.9"
printf '{"object":{"sha":"%s","type":"commit"}}' "$tag_sha" \
    > "$T/api/obj-tagobject11111111111111111111111111111111"
mirror_tag v9.9.9 "$tag_sha" \
    || fail "an annotated mirror tag at the released commit must resume, not abort: $(ann)"
ann | grep -q 'already present on the mirror' || fail "resume must be announced: $(ann)"
ok "a 422 on an annotated mirror tag dereferences instead of falsely aborting"

other_sha=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
printf '{"sha":"%s"}' "$other_sha" > "$T/api/commit-$other_sha"
mirror_tag v9.9.9 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    && fail "a mirror tag pointing elsewhere must abort the publication"
ann | grep -q 'already exists on the mirror at' || fail "the collision must be named: $(ann)"
ok "a mirror tag at a different revision aborts instead of being overwritten"

echo 500 > "$T/api/tag-code"
mirror_tag v9.9.9 "$tag_sha" && fail "an unexpected status must not be treated as success"
ann | grep -q 'HTTP 500' || fail "the status must be named: $(ann)"
rm -f "$T/api/tag-code" "$T/api/ref-v9.9.9"
ok "an unexpected mirror status aborts with the status named"

mirror_tag v9.9.9 cccccccccccccccccccccccccccccccccccccccc \
    && fail "a revision absent from the mirror must abort before tagging"
ann | grep -q 'has not reached the GitHub mirror' || fail "the wait failure must be named: $(ann)"
ok "a revision that never reaches the mirror aborts instead of tagging the wrong commit"

notes="$T/notes.md"
echo "release notes" > "$notes"
asset="$T/substrate_0.2.0_linux_amd64.tar.gz"
head -c 2048 /dev/urandom > "$asset"
plan="$T/plan.txt"
: > "$plan"
forge() {
    env -u GH_TOKEN -u GITHUB_TOKEN -u SUBSTRATE_FORGE_TOKEN \
        SUBSTRATE_FORGE_DRYRUN=1 GITHUB_API_URL=https://api.github.com \
        GITHUB_REPOSITORY=mp-pinheiro/substrate \
        bash "$KIT_ROOT/core/forge.sh" "$@"
}
id=$(forge create-release v0.2.0 v0.2.0 false "$notes" "$head_sha" 2>>"$plan") \
    || fail "credential-free dry-run create-release exited $?: $(cat "$plan")"
[ "$id" = dryrun-v0.2.0 ] || fail "dry-run must yield a synthetic id, got $id"
forge upload-asset "$id" "$asset" >/dev/null 2>>"$plan" || fail "dry-run upload-asset exited $?"
forge prune-prereleases v0.2.0-nightly. 14 >/dev/null 2>>"$plan" || fail "dry-run prune exited $?"
grep -q 'DRYRUN create-release .*host=https://api.github.com .*tag=v0.2.0 prerelease=false' "$plan" \
    || fail "dry-run must record the release it would create: $(cat "$plan")"
grep -q 'DRYRUN upload-asset .*bytes=2048' "$plan" \
    || fail "dry-run must record the asset it would upload: $(cat "$plan")"
grep -q 'DRYRUN prune .*listing skipped' "$plan" \
    || fail "dry-run prune must not perform a live listing: $(cat "$plan")"
ok "dry-run publishes nothing, needs no credentials, and reports the exact release plan"

forge create-release v0.2.0 v0.2.0 false "$T/does-not-exist.md" "$head_sha" >/dev/null 2>&1 \
    && fail "dry-run must reject a missing notes file exactly as the live path does"
ok "dry-run is no more permissive than the live path about missing inputs"

ok "release lane verified locally — no forge round-trip required"
