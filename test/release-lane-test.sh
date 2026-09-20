#!/usr/bin/env bash
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'release-lane-test FAIL: %s\n' "$1" >&2; exit 1; }
ok() { printf '\033[0;32m[ok]\033[0m release-lane-test: %s\n' "$*"; }

T=$(mktemp -d) || fail "scratch dir"
trap 'rm -rf "$T"' EXIT

repo="$T/repo"
mkdir -p "$repo" || fail "scratch repo"
cd "$repo" || fail "cannot enter the scratch repo"
git init -q -b main . || fail "git init"
git config user.email t@t && git config user.name t
echo 0.2.0 > VERSION
git add VERSION && git commit -qm init || fail "seed commit"
head_sha=$(git rev-parse HEAD)

identity() {
    env RELEASE_EVENT="$1" RELEASE_CHANNEL="${2:-}" RELEASE_HEAD_SHA="${3:-$head_sha}" \
        RELEASE_DATE=20260101 RELEASE_MIRROR_TOKEN= \
        bash "$KIT_ROOT/core/release-identity.sh" 2>"$T/err"
}

field() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }

out=$(identity workflow_dispatch "") || fail "stable identity exited $?"
[ "$(field "$out" version)" = 0.2.0 ] || fail "stable version: $out"
[ "$(field "$out" channel)" = release ] || fail "stable channel: $out"
[ "$(field "$out" prerelease)" = false ] || fail "stable prerelease: $out"
[ "$(field "$out" skip)" = false ] || fail "stable skip: $out"
ok "first stable cut resolves v0.2.0 on the release channel"

out=$(identity schedule "") || fail "nightly identity exited $?"
[ "$(field "$out" version)" = 0.2.0-nightly.20260101 ] || fail "nightly version: $out"
[ "$(field "$out" prerelease)" = true ] || fail "nightly prerelease: $out"
ok "nightly with no stable tag keeps the current base"

git tag -a v0.2.0 -m release || fail "annotated tag"
out=$(identity schedule "") || fail "post-stable nightly exited $?"
[ "$(field "$out" version)" = 0.3.0-nightly.20260101 ] \
    || fail "nightly must sort above the published stable, got: $out"
ok "nightly bumps past a published stable so semver keeps ordering"

git commit -q --allow-empty -m next || fail "second commit"
next_sha=$(git rev-parse HEAD)
head_sha="$next_sha"

if identity workflow_dispatch "" >/dev/null 2>&1; then
    fail "re-cutting a published stable from a new revision must be refused"
fi
grep -q 'already points at' "$T/err" || fail "refusal must name the collision: $(cat "$T/err")"
ok "re-cutting a published stable from a new revision is refused"

out=$(identity workflow_dispatch "" "$(git rev-list -n1 v0.2.0)") \
    || fail "resuming the same revision must be allowed"
[ "$(field "$out" skip)" = false ] || fail "resume must not skip: $out"
grep -q 'resuming publication' "$T/err" || fail "resume must be announced: $(cat "$T/err")"
ok "re-running at the published revision resumes instead of failing"

git tag -a v0.3.0-nightly.20260101 -m nightly || fail "nightly tag"
git commit -q --allow-empty -m third || fail "third commit"
head_sha=$(git rev-parse HEAD)
out=$(identity schedule "") || fail "cron collision must not fail the run"
[ "$(field "$out" skip)" = true ] || fail "cron collision must skip: $out"
grep -q 'nothing to cut' "$T/err" || fail "skip must be announced: $(cat "$T/err")"
ok "cron re-hitting today's nightly skips instead of reding the run"

if identity workflow_dispatch nightly >/dev/null 2>&1; then
    fail "manual re-dispatch of an existing nightly must be refused"
fi
ok "manual re-dispatch of the same nightly is refused"

git tag -d v0.3.0-nightly.20260101 >/dev/null || fail "tag cleanup"
out=$(identity schedule "") || fail "clean cron exited $?"
[ "$(field "$out" skip)" = false ] || fail "a cron with no tag today must proceed: $out"
ok "cron with no tag for today proceeds to a fresh nightly"

tagobj=$(git rev-parse v0.2.0)
commit=$(git rev-list -n1 v0.2.0)
[ "$tagobj" != "$commit" ] || fail "fixture must use an annotated tag to exercise dereference"
out=$(identity workflow_dispatch "" "$commit") || fail "resume at the dereferenced commit exited $?"
grep -q 'resuming publication' "$T/err" \
    || fail "an annotated tag must compare by its commit, not its tag object: $(cat "$T/err")"
if identity workflow_dispatch "" "$tagobj" >/dev/null 2>&1; then
    fail "the tag object sha must not be mistaken for the released commit"
fi
ok "annotated tags dereference to the commit, not the tag object"

echo -n > VERSION
if identity workflow_dispatch "" >/dev/null 2>&1; then
    fail "an empty VERSION must be refused, not published as v"
fi
grep -q "missing or empty" "$T/err" || fail "empty VERSION must be named: $(cat "$T/err")"
ok "an empty VERSION file is refused before anything is tagged"
echo 0.2.0 > VERSION

notes="$T/notes.md"
echo "release notes" > "$notes"
asset="$T/substrate_0.2.0_linux_amd64.tar.gz"
head -c 2048 /dev/urandom > "$asset"
export SUBSTRATE_FORGE_DRYRUN=1 GITHUB_API_URL=https://api.github.com \
    GITHUB_REPOSITORY=mp-pinheiro/substrate
plan="$T/plan.txt"
: > "$plan"
id=$(bash "$KIT_ROOT/core/forge.sh" create-release v0.2.0 v0.2.0 false "$notes" "$head_sha" 2>>"$plan") \
    || fail "dry-run create-release exited $?"
[ "$id" = dryrun-v0.2.0 ] || fail "dry-run must yield a synthetic id, got $id"
bash "$KIT_ROOT/core/forge.sh" upload-asset "$id" "$asset" >/dev/null 2>>"$plan" \
    || fail "dry-run upload-asset exited $?"
grep -q 'DRYRUN create-release .*tag=v0.2.0 prerelease=false' "$plan" \
    || fail "dry-run must record the release it would create: $(cat "$plan")"
grep -q 'DRYRUN upload-asset .*bytes=2048' "$plan" \
    || fail "dry-run must record the asset it would upload: $(cat "$plan")"
ok "dry-run publishes nothing and reports the exact release plan"

ok "release lane verified locally — no forge round-trip required"
