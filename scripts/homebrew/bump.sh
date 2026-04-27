#!/usr/bin/env bash
# Rewrite the version, urls, and sha256s in scripts/homebrew/fermix.rb
# from the freshly built releases.json. Used by the release pipeline
# to push a PR to tezra-io/homebrew-tap.
#
# Inputs:
#   $RELEASES_JSON  Path to the releases.json emitted by
#                   scripts/release/build_releases_json.sh
#   $FORMULA        Optional path to the formula to rewrite.
#                   Defaults to scripts/homebrew/fermix.rb relative
#                   to this script.

set -euo pipefail

: "${RELEASES_JSON:?RELEASES_JSON env var required}"

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
formula="${FORMULA:-$repo_root/scripts/homebrew/fermix.rb}"

[ -f "$RELEASES_JSON" ] || { echo "bump.sh: no manifest at $RELEASES_JSON" >&2; exit 1; }
[ -f "$formula" ] || { echo "bump.sh: no formula at $formula" >&2; exit 1; }

require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "bump.sh: missing $1" >&2; exit 1; }; }
require_cmd jq

version="$(jq -r '.latest' "$RELEASES_JSON")"
[ "$version" != "null" ] && [ -n "$version" ] || { echo "bump.sh: no .latest in manifest" >&2; exit 1; }

# Grab url + sha for each (target). Targets must match the Homebrew on_*/on_* blocks.
get_field() {
  jq -r --arg t "$1" --arg f "$2" \
    '.releases[] | select(.version == $version) | .artifacts[] | select(.target == $t) | .[$f]' \
    --arg version "$version" "$RELEASES_JSON"
}

url_macos_arm="$(get_field macos-aarch64 url)"
sha_macos_arm="$(get_field macos-aarch64 sha256)"
url_macos_intel="$(get_field macos-x86_64 url)"
sha_macos_intel="$(get_field macos-x86_64 sha256)"
url_linux_arm="$(get_field linux-aarch64 url)"
sha_linux_arm="$(get_field linux-aarch64 sha256)"
url_linux_intel="$(get_field linux-x86_64 url)"
sha_linux_intel="$(get_field linux-x86_64 sha256)"

for v in "$url_macos_arm" "$sha_macos_arm" "$url_macos_intel" "$sha_macos_intel" \
         "$url_linux_arm" "$sha_linux_arm" "$url_linux_intel" "$sha_linux_intel"; do
  [ -n "$v" ] || { echo "bump.sh: incomplete artifact set in manifest for $version" >&2; exit 1; }
done

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

awk -v ver="$version" \
    -v url_marm="$url_macos_arm" -v sha_marm="$sha_macos_arm" \
    -v url_mintel="$url_macos_intel" -v sha_mintel="$sha_macos_intel" \
    -v url_larm="$url_linux_arm" -v sha_larm="$sha_linux_arm" \
    -v url_lintel="$url_linux_intel" -v sha_lintel="$sha_linux_intel" '
  /^  version "/ { print "  version \"" ver "\""; next }

  # The url line carries the target name; remember which target this
  # block belongs to so the next sha256 line picks the matching hash.
  /url .*fermix_macos_aarch64/ { last="macos_aarch64"; print "      url \"" url_marm "\""; next }
  /url .*fermix_macos_x86_64/  { last="macos_x86_64";  print "      url \"" url_mintel "\""; next }
  /url .*fermix_linux_aarch64/ { last="linux_aarch64"; print "      url \"" url_larm "\""; next }
  /url .*fermix_linux_x86_64/  { last="linux_x86_64";  print "      url \"" url_lintel "\""; next }

  /sha256 / && last == "macos_aarch64" { print "      sha256 \"" sha_marm "\"";  last=""; next }
  /sha256 / && last == "macos_x86_64"  { print "      sha256 \"" sha_mintel "\""; last=""; next }
  /sha256 / && last == "linux_aarch64" { print "      sha256 \"" sha_larm "\"";  last=""; next }
  /sha256 / && last == "linux_x86_64"  { print "      sha256 \"" sha_lintel "\""; last=""; next }

  { print }
' "$formula" > "$tmp"

mv "$tmp" "$formula"
echo "bump.sh: rewrote $formula to version $version"
