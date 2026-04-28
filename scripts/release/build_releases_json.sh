#!/usr/bin/env bash
# Emit releases.json describing the current release's signed artifacts.
#
# Inputs:
#   $VERSION  Tag name with or without leading "v" (e.g. "v0.1.0" or "0.1.0").
#   $REPO     GitHub repository in "owner/name" form.
#
# Reads from ./burrito_out/ (relative to repo root) and writes the JSON
# document to stdout. The CI workflow pipes it to burrito_out/releases.json.
#
# Schema (subject to change pre-1.0 — bump schema_version on breaks):
#   {
#     "schema_version": 1,
#     "latest": "0.1.0",
#     "releases": [
#       {
#         "version": "0.1.0",
#         "published_at": "2026-04-26T18:00:00Z",
#         "artifacts": [
#           {
#             "target": "macos-aarch64",
#             "url": "https://github.com/<owner>/<name>/releases/download/v0.1.0/fermix_macos_aarch64",
#             "sha256": "<hex>",
#             "sig_url": "<url>.sig",
#             "cert_url": "<url>.pem"
#           }
#         ]
#       }
#     ]
#   }

set -euo pipefail

: "${VERSION:?VERSION env var required (with or without leading v)}"
: "${REPO:?REPO env var required (owner/name)}"

version="${VERSION#v}"
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
artifacts_dir="$repo_root/burrito_out"

if [ ! -d "$artifacts_dir" ]; then
  echo "build_releases_json.sh: $artifacts_dir not found" >&2
  exit 1
fi

base_url="https://github.com/${REPO}/releases/download/v${version}"
published_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

artifacts="[]"
for bin in "$artifacts_dir"/fermix_*; do
  case "$bin" in *.sig|*.pem|*.sha256) continue ;; esac
  [ -f "$bin" ] || continue

  filename="$(basename "$bin")"
  target="${filename#fermix_}"
  # Convert only the first underscore (the os/arch separator) so x86_64
  # stays "x86_64", not "x86-64". Manifest consumers (the installer,
  # upgrader, Homebrew bumper) all match on macos-x86_64 / linux-x86_64.
  target="${target/_/-}"
  sha256="$(sha256sum "$bin" | awk '{print $1}')"

  artifacts="$(jq -c \
    --arg target "$target" \
    --arg url "$base_url/$filename" \
    --arg sig_url "$base_url/$filename.sig" \
    --arg cert_url "$base_url/$filename.pem" \
    --arg sha256 "$sha256" \
    '. + [{
      target: $target,
      url: $url,
      sha256: $sha256,
      sig_url: $sig_url,
      cert_url: $cert_url
    }]' <<< "$artifacts")"
done

if [ "$artifacts" = "[]" ]; then
  echo "build_releases_json.sh: no fermix_* artifacts found in $artifacts_dir" >&2
  exit 1
fi

jq -n \
  --arg version "$version" \
  --arg published_at "$published_at" \
  --argjson artifacts "$artifacts" \
  '{
    schema_version: 1,
    latest: $version,
    releases: [{
      version: $version,
      published_at: $published_at,
      artifacts: $artifacts
    }]
  }'
