#!/usr/bin/env bash
# Emit releases.json describing the current release's signed artifacts.
#
# Inputs:
#   $VERSION       Tag name with or without leading "v" (e.g. "v0.1.0" or "0.1.0").
#   $REPO          GitHub repository in "owner/name" form.
#   $PACKAGES_DIR  Directory holding this release's four Linux packages.
#
# Reads from ./burrito_out/ (relative to repo root) and from $PACKAGES_DIR, and
# writes the JSON document to stdout. The CI workflow pipes it to
# burrito_out/releases.json.
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
#         ],
#         "packages": {
#           "linux-x86_64": {
#             "deb": { "name": "fermix_0.1.0_amd64.deb", "url": "...", "sha256": "<hex>" },
#             "rpm": { "name": "fermix-0.1.0-1.x86_64.rpm", "url": "...", "sha256": "<hex>" }
#           }
#         }
#       }
#     ]
#   }
#
# The "packages" object sits after "artifacts" and carries no "target" key,
# because scripts/install.sh reads this document with a line-scanning awk that
# keys on "target" and takes the next "url"/"sha256" it sees.

set -euo pipefail

: "${VERSION:?VERSION env var required (with or without leading v)}"
: "${REPO:?REPO env var required (owner/name)}"
: "${PACKAGES_DIR:?PACKAGES_DIR env var required (the Linux packages of this release)}"

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

if [ ! -d "$PACKAGES_DIR" ]; then
  echo "build_releases_json.sh: $PACKAGES_DIR not found" >&2
  exit 1
fi

packages="{}"
for package in "$PACKAGES_DIR"/*.deb "$PACKAGES_DIR"/*.rpm; do
  [ -f "$package" ] || continue

  filename="$(basename "$package")"
  case "$filename" in
    *_amd64.deb) package_target="linux-x86_64"; format="deb" ;;
    *_arm64.deb) package_target="linux-aarch64"; format="deb" ;;
    *.x86_64.rpm) package_target="linux-x86_64"; format="rpm" ;;
    *.aarch64.rpm) package_target="linux-aarch64"; format="rpm" ;;
    *)
      echo "build_releases_json.sh: unrecognized package $filename" >&2
      exit 1
      ;;
  esac

  sha256="$(sha256sum "$package" | awk '{print $1}')"

  packages="$(jq -c \
    --arg target "$package_target" \
    --arg format "$format" \
    --arg name "$filename" \
    --arg url "$base_url/$filename" \
    --arg sha256 "$sha256" \
    '.[$target] += {($format): {name: $name, url: $url, sha256: $sha256}}' <<< "$packages")"
done

# Both families for both architectures, or this release is not describable: an
# incomplete set is what leaves one population on the previous version.
missing="$(jq -r '
  ["linux-x86_64", "linux-aarch64"]
  - [ to_entries[] | select(.value | has("deb")) | select(.value | has("rpm")) | .key ]
  | join(" ")
' <<< "$packages")"

if [ -n "$missing" ]; then
  echo "build_releases_json.sh: $PACKAGES_DIR has no complete deb and rpm pair for: $missing" >&2
  exit 1
fi

jq -n \
  --arg version "$version" \
  --arg published_at "$published_at" \
  --argjson artifacts "$artifacts" \
  --argjson packages "$packages" \
  '{
    schema_version: 1,
    latest: $version,
    releases: [{
      version: $version,
      published_at: $published_at,
      artifacts: $artifacts,
      packages: $packages
    }]
  }'
