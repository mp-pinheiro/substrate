#!/usr/bin/env bash
set -euo pipefail

app_id="${GH_APP_ID:?GH_APP_ID is required}"
repo="${GH_MIRROR_REPO:?GH_MIRROR_REPO is required}"
permissions="${GH_APP_PERMISSIONS:-}"
[ -n "$permissions" ] || permissions='{"contents":"write"}'
: "${GH_APP_PRIVATE_KEY:?GH_APP_PRIVATE_KEY is required}"

key_file="$(mktemp)"
response="$(mktemp)"
trap 'rm -f "$key_file" "$response"' EXIT
chmod 600 "$key_file"
printf '%s\n' "$GH_APP_PRIVATE_KEY" > "$key_file"

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

now=$(date +%s)
header=$(printf '{"typ":"JWT","alg":"RS256"}' | b64url)
payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' \
  "$((now - 60))" "$((now + 480))" "$app_id" | b64url)
signature=$(printf '%s' "${header}.${payload}" \
  | openssl dgst -sha256 -sign "$key_file" -binary \
  | b64url)
jwt="${header}.${payload}.${signature}"

code=$(curl -sS -o "$response" -w '%{http_code}' --max-time 30 \
  -H "Authorization: Bearer ${jwt}" \
  -H 'Accept: application/vnd.github+json' \
  "https://api.github.com/repos/${repo}/installation")
if [ "$code" != "200" ]; then
  echo "App ${app_id}: installation lookup on ${repo} failed (HTTP ${code})" >&2
  head -c 300 "$response" >&2
  echo >&2
  exit 1
fi
installation=$(jq -r '.id // empty' "$response")
if [ -z "$installation" ]; then
  echo "App ${app_id} is not installed on ${repo}" >&2
  exit 1
fi

code=$(curl -sS -o "$response" -w '%{http_code}' --max-time 30 -X POST \
  -H "Authorization: Bearer ${jwt}" \
  -H 'Accept: application/vnd.github+json' \
  --data "$(jq -n --arg r "${repo#*/}" --argjson p "$permissions" \
              '{repositories:[$r],permissions:$p}')" \
  "https://api.github.com/app/installations/${installation}/access_tokens")
if [ "$code" != "201" ]; then
  echo "installation ${installation} refused a scoped token (HTTP ${code})" >&2
  echo "requested permissions: ${permissions}" >&2
  head -c 300 "$response" >&2
  echo >&2
  exit 1
fi
token=$(jq -r '.token // empty' "$response")
if [ -z "$token" ]; then
  echo "installation ${installation} returned no token in a 201 response" >&2
  exit 1
fi
printf '%s\n' "$token"
