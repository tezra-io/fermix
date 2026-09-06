#!/usr/bin/env bash
# Fail closed when a tag already has a published GitHub Release.

set -euo pipefail

fail() {
  printf 'refuse_published_release.sh: %s\n' "$1" >&2
  exit 1
}

usage() {
  printf 'usage: %s <owner/repository> <tag>\n' "$0" >&2
  exit 2
}

[ "$#" -eq 2 ] || usage

repository="$1"
tag="$2"
: "${GH_TOKEN:?GH_TOKEN is required}"

[[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
  fail "repository must use the owner/name form"
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]] ||
  fail "tag must be a Fermix release tag"

runtime_parent="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
[ -d "$runtime_parent" ] || fail "temporary directory does not exist"
response="$(mktemp "$runtime_parent/fermix-release-state.XXXXXX")"
trap 'rm -f -- "$response"' EXIT

encoded_tag="$(jq -rn --arg tag "$tag" '$tag | @uri')"
if ! status="$(curl --silent --show-error \
  --output "$response" \
  --write-out '%{http_code}' \
  --header "Authorization: Bearer $GH_TOKEN" \
  --header "Accept: application/vnd.github+json" \
  --header "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/repos/$repository/releases/tags/$encoded_tag")"; then
  fail "cannot query GitHub release state"
fi

case "$status" in
  200)
    draft="$(jq -r 'if (.draft | type) == "boolean" then (.draft | tostring) else error("invalid draft field") end' "$response")" ||
      fail "GitHub returned invalid release metadata"
    if [ "$draft" = true ]; then
      printf 'Reusing the existing draft release for %s\n' "$tag"
      exit 0
    fi
    fail "the $tag release is already published and immutable"
    ;;
  404)
    exit 0
    ;;
  *)
    fail "cannot determine whether $tag is already published (HTTP $status)"
    ;;
esac
