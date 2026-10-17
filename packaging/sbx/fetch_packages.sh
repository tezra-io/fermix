#!/usr/bin/env bash
# Put the signed Fermix .deb for each kit architecture beside the kit, so the
# kit's Dockerfile can COPY them (M64). The release must be published; each
# package is checked against its sha256 sidecar and its cosign signature from
# the release workflow, the same identity `fermix upgrade` and install.sh pin.
# Beside them goes the Caddy binary the kit's provider relay runs: one pinned
# Caddy release, each tarball checked against the sha512 checksums file that
# Caddy's own release workflow signed.
#
#   packaging/sbx/fetch_packages.sh 0.15.0
#
# Writes packaging/sbx/fermix_{amd64,arm64}.deb and caddy_{amd64,arm64}
# (gitignored), and leaves them as they were unless all four verify.

set -euo pipefail

usage() {
  echo "usage: fetch_packages.sh <MAJOR.MINOR.PATCH>" >&2
  exit 2
}

fail() {
  echo "fetch_packages.sh: $*" >&2
  exit 1
}

[ "$#" -eq 1 ] || usage
version="$1"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || usage

command -v cosign >/dev/null 2>&1 || fail "cosign is required: the kit ships only a signature-checked package"
command -v curl >/dev/null 2>&1 || fail "curl is required"

readonly origin="https://github.com/tezra-io/fermix/releases/download/v${version}"
readonly identity="https://github.com/tezra-io/fermix/.github/workflows/release.yml@refs/tags/v${version}"
readonly issuer="https://token.actions.githubusercontent.com"
readonly caddy_version=2.11.7
readonly caddy_origin="https://github.com/caddyserver/caddy/releases/download/v${caddy_version}"
readonly caddy_identity="https://github.com/caddyserver/caddy/.github/workflows/release.yml@refs/tags/v${caddy_version}"
kit_dir="$(cd "$(dirname "$0")" && pwd -P)"
readonly kit_dir

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

sha512_of() {
  if command -v sha512sum >/dev/null 2>&1; then
    sha512sum "$1" | awk '{print $1}'
  else
    shasum -a 512 "$1" | awk '{print $1}'
  fi
}

verify_signature() {
  local blob="$1" signer="$2"
  cosign verify-blob \
    --certificate "$work/$blob.pem" \
    --signature "$work/$blob.sig" \
    --certificate-identity "$signer" \
    --certificate-oidc-issuer "$issuer" \
    "$work/$blob" >/dev/null 2>"$work/cosign.err" ||
    fail "$blob: cosign verify-blob failed: $(cat "$work/cosign.err")"
}

fetch_one() {
  local arch="$1" name="fermix_${version}_$1.deb" expected actual
  for suffix in "" .sha256 .sig .pem; do
    curl -fsSL --retry 3 -o "$work/$name$suffix" "$origin/$name$suffix" ||
      fail "cannot download $origin/$name$suffix"
  done

  expected="$(awk '{print $1; exit}' "$work/$name.sha256")"
  actual="$(sha256_of "$work/$name")"
  [ "$expected" = "$actual" ] || fail "$name: sha256 $actual does not match the release's $expected"

  verify_signature "$name" "$identity"

  mv "$work/$name" "$work/fermix_${arch}.deb"
  echo "fetch_packages.sh: fermix_${arch}.deb is Fermix ${version}, sha256 ${actual}, signature verified"
}

# Caddy signs one checksums file per release rather than each tarball, so the
# signature is checked once and each tarball against the line it signed.
fetch_caddy() {
  local sums="caddy_${caddy_version}_checksums.txt" arch name expected actual
  for suffix in "" .sig .pem; do
    curl -fsSL --retry 3 -o "$work/$sums$suffix" "$caddy_origin/$sums$suffix" ||
      fail "cannot download $caddy_origin/$sums$suffix"
  done
  verify_signature "$sums" "$caddy_identity"

  for arch in amd64 arm64; do
    name="caddy_${caddy_version}_linux_${arch}.tar.gz"
    curl -fsSL --retry 3 -o "$work/$name" "$caddy_origin/$name" ||
      fail "cannot download $caddy_origin/$name"
    expected="$(awk -v name="$name" '$2 == name {print $1; exit}' "$work/$sums")"
    actual="$(sha512_of "$work/$name")"
    [ -n "$expected" ] && [ "$expected" = "$actual" ] ||
      fail "$name: sha512 $actual does not match the signed checksums' ${expected:-(no line)}"

    mkdir "$work/caddy-$arch"
    tar -xzf "$work/$name" -C "$work/caddy-$arch" caddy || fail "$name holds no caddy binary"
    mv "$work/caddy-$arch/caddy" "$work/caddy_${arch}"
    echo "fetch_packages.sh: caddy_${arch} is Caddy ${caddy_version}, sha512 checked against the signed checksums"
  done
}

# All four are checked before any replaces what is there, so the kit never
# holds files from two releases.
fetch_one amd64
fetch_one arm64
fetch_caddy
mv "$work/fermix_amd64.deb" "$work/fermix_arm64.deb" "$work/caddy_amd64" "$work/caddy_arm64" "$kit_dir/"
