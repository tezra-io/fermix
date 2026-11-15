#!/usr/bin/env bash
# Print the digest table https://fermix.ai/install/releases serves, for one
# release, from the release rail's own signed files.
#
#   build_install_table.sh <candidate-root> <version>
#
# <candidate-root> is the signed release candidate as the rail downloads it:
# burrito_out/ holds the four standalone binaries, linux_packages/ the four
# packages and always_on/ the Always On server script that the installer's
# --always-on runs, each with its .sig and .pem beside it. Every file is checked with
# cosign against the release workflow's identity for v<version> and then hashed
# here, so a row is never copied from a sidecar or a manifest. The table is the
# one the site's pin script writes (scripts/pin-engine-release.mjs in
# tezra-io/fermix-site), cut to this release:
#
#   format 1
#   latest <version>
#   <version> <sha256> <file>
#
# The release rail serves it to scripts/install.sh in place of fermix.ai, which
# lists a release only once the site pins it. Nothing is printed unless every
# file verifies.

set -euo pipefail

fail() {
  printf 'build_install_table.sh: %s\n' "$1" >&2
  exit 1
}

[ "$#" -eq 2 ] || {
  printf 'usage: %s <candidate-root> <version>\n' "$0" >&2
  exit 2
}

root="$1"
version="$2"

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "expected a release such as 0.18.0, got '$version'"
[ -d "$root" ] || fail "candidate root not found: $root"
command -v cosign >/dev/null 2>&1 || fail "cosign is required to verify the files before they are listed"

identity="https://github.com/tezra-io/fermix/.github/workflows/release.yml@refs/tags/v${version}"
issuer="https://token.actions.githubusercontent.com"

# Every file scripts/install.sh can fetch, as the release workflow names it.
files=(
  "burrito_out/fermix_linux_x86_64"
  "burrito_out/fermix_linux_aarch64"
  "burrito_out/fermix_macos_aarch64"
  "burrito_out/fermix_macos_x86_64"
  "linux_packages/fermix_${version}_amd64.deb"
  "linux_packages/fermix_${version}_arm64.deb"
  "linux_packages/fermix-${version}-1.x86_64.rpm"
  "linux_packages/fermix-${version}-1.aarch64.rpm"
  "always_on/fermix_always_on.sh"
)

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

rows=""
for file in "${files[@]}"; do
  path="$root/$file"
  for part in "$path" "$path.sig" "$path.pem"; do
    [ -f "$part" ] || fail "missing $part"
  done
  cosign verify-blob \
    --certificate "$path.pem" \
    --signature "$path.sig" \
    --certificate-identity "$identity" \
    --certificate-oidc-issuer "$issuer" \
    "$path" >&2 || fail "cosign could not verify $file against $identity"
  rows+="$version $(sha256 "$path") $(basename "$file")"$'\n'
done

printf 'format 1\nlatest %s\n%s' "$version" "$rows"
