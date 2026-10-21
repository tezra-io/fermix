#!/bin/sh
# Build-time helper for the Fermix kit's recipe, run in its fetch stage and
# never shipped in the kit: downloads the signed Fermix release package and
# the Caddy binary for one architecture, and puts them in OUT_DIR only after
# both verify.
#
#   fetch-verified.sh <fermix version> <amd64|arm64> <out dir>
#
# The Fermix package is checked against its sha256 sidecar and its cosign
# signature from Fermix's release workflow, the identity `fermix upgrade` and
# install.sh pin. Caddy signs one checksums file per release rather than each
# tarball, so that signature is checked once and the tarball against the
# sha512 line it signed.
set -eu

readonly caddy_version=2.11.7
readonly issuer="https://token.actions.githubusercontent.com"

usage() {
  echo "usage: fetch-verified.sh <MAJOR.MINOR.PATCH> <amd64|arm64> <out dir>" >&2
  exit 2
}

fail() {
  echo "fetch-verified.sh: $*" >&2
  exit 1
}

[ "$#" -eq 3 ] || usage
version="$1"
arch="$2"
out_dir="$3"
echo "$version" | grep -Eqx '[0-9]+\.[0-9]+\.[0-9]+' || usage
case "$arch" in
  amd64 | arm64) ;;
  *) usage ;;
esac

command -v cosign >/dev/null 2>&1 || fail "cosign is required: the kit ships only signature-checked downloads"
command -v curl >/dev/null 2>&1 || fail "curl is required"

readonly origin="https://github.com/tezra-io/fermix/releases/download/v${version}"
readonly identity="https://github.com/tezra-io/fermix/.github/workflows/release.yml@refs/tags/v${version}"
readonly caddy_origin="https://github.com/caddyserver/caddy/releases/download/v${caddy_version}"
readonly caddy_identity="https://github.com/caddyserver/caddy/.github/workflows/release.yml@refs/tags/v${caddy_version}"

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

download() {
  curl -fsSL --retry 3 -o "$work/$2" "$1/$2" || fail "cannot download $1/$2"
}

verify_signature() {
  cosign verify-blob \
    --certificate "$work/$1.pem" \
    --signature "$work/$1.sig" \
    --certificate-identity "$2" \
    --certificate-oidc-issuer "$issuer" \
    "$work/$1" >/dev/null 2>"$work/cosign.err" ||
    fail "$1: cosign verify-blob failed: $(cat "$work/cosign.err")"
}

fetch_fermix() {
  name="fermix_${version}_${arch}.deb"
  for suffix in "" .sha256 .sig .pem; do
    download "$origin" "$name$suffix"
  done

  expected="$(awk '{print $1; exit}' "$work/$name.sha256")"
  actual="$(sha256sum "$work/$name" | awk '{print $1}')"
  [ "$expected" = "$actual" ] || fail "$name: sha256 $actual does not match the release's $expected"
  verify_signature "$name" "$identity"

  mv "$work/$name" "$work/fermix.deb"
  echo "fetch-verified.sh: fermix.deb is Fermix ${version} for ${arch}, sha256 ${actual}, signature verified"
}

fetch_caddy() {
  sums="caddy_${caddy_version}_checksums.txt"
  for suffix in "" .sig .pem; do
    download "$caddy_origin" "$sums$suffix"
  done
  verify_signature "$sums" "$caddy_identity"

  name="caddy_${caddy_version}_linux_${arch}.tar.gz"
  download "$caddy_origin" "$name"
  expected="$(awk -v name="$name" '$2 == name {print $1; exit}' "$work/$sums")"
  actual="$(sha512sum "$work/$name" | awk '{print $1}')"
  [ -n "$expected" ] && [ "$expected" = "$actual" ] ||
    fail "$name: sha512 $actual does not match the signed checksums' ${expected:-(no line)}"

  mkdir "$work/caddy-tree"
  tar -xzf "$work/$name" -C "$work/caddy-tree" caddy || fail "$name holds no caddy binary"
  mv "$work/caddy-tree/caddy" "$work/caddy"
  echo "fetch-verified.sh: caddy is Caddy ${caddy_version} for ${arch}, sha512 checked against the signed checksums"
}

fetch_fermix
fetch_caddy
# Both are checked before either is placed, so the stage never holds one
# verified file beside an unverified one.
mkdir -p "$out_dir"
mv "$work/fermix.deb" "$work/caddy" "$out_dir/"
