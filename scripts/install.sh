#!/usr/bin/env sh
# fermix installer.
#
# Detects (os, arch), downloads the matching signed binary from the
# latest GitHub Release, sha256-verifies it against releases.json,
# cosign-verifies it when cosign is installed, and drops it in
# /usr/local/bin (with sudo) or ~/.local/bin (no sudo) depending on
# what's writable. Optionally runs `fermix setup` at the end.
#
#   curl -fsSL https://fermix.sh/install | sh
#   curl -fsSL https://fermix.sh/install | sh -s -- --no-setup
#   curl -fsSL https://fermix.sh/install | sh -s -- --prefix /opt/fermix/bin
#
# Hard-fails on any unsupported (os, arch) pair, missing tooling, or
# sha256 mismatch. There is no "best effort" path that drops a
# half-installed binary somewhere — partial installs make `fermix
# upgrade` and `fermix doctor` lie about reality.

set -eu

REPO="tezra-io/fermix"
MANIFEST_URL="https://github.com/${REPO}/releases/latest/download/releases.json"
RUN_SETUP=1
PREFIX=""

# Every artifact URL the release pipeline emits is rooted here — the exact base
# scripts/release/build_releases_json.sh builds. Must stay identical to
# @artifact_origin in apps/fermix_core/lib/fermix/cli/upgrade/manifest.ex: one
# document, one trust decision, and the two readers of it must not disagree
# about which URLs in it are ours.
#
# Honest accounting: the manifest and the artifacts come from the same host under
# the same TLS and fall in the same compromise event, so this is not a defence
# against a compromised GitHub — cosign is. What the pin removes is the
# blind-fetch-anywhere primitive: the binary, its signature and its certificate
# are all downloaded BEFORE anything is verified, so whoever can edit
# releases.json could otherwise make this machine issue three arbitrary
# pre-verification GETs to a host of their choosing.
ARTIFACT_ORIGIN="https://github.com/${REPO}/releases/download/"

# Keyless-signing identity of the release workflow. Must stay identical to
# apps/fermix_core/lib/fermix/cli/upgrade/cosign.ex, which pins the same issuer
# and the same workflow@refs/tags/v<version> identity for `fermix upgrade`.
COSIGN_ISSUER="https://token.actions.githubusercontent.com"
COSIGN_IDENTITY_PREFIX="https://github.com/${REPO}/.github/workflows/release.yml@refs/tags/v"

usage() {
  cat <<USAGE
Usage: install.sh [--prefix DIR] [--no-setup]

Options:
  --prefix DIR   Install location for the fermix binary
                 (default: /usr/local/bin if writable or sudo, else ~/.local/bin)
  --no-setup     Skip the interactive 'fermix setup' wizard at the end
  --help, -h     Show this message
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX="${2:?--prefix requires a value}"; shift 2 ;;
    --no-setup) RUN_SETUP=0; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "install.sh: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

abort() {
  printf 'install.sh: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || abort "missing required command: $1"
}

require_cmd curl
require_cmd uname
require_cmd mkdir
require_cmd install
require_cmd mktemp

# Either shasum (BSD/macOS) or sha256sum (most Linux distros) is fine.
if ! command -v shasum >/dev/null 2>&1 && ! command -v sha256sum >/dev/null 2>&1; then
  abort "missing required command: shasum or sha256sum"
fi

detect_os() {
  case "$(uname -s)" in
    Darwin) printf macos ;;
    Linux) printf linux ;;
    *) abort "unsupported OS: $(uname -s)" ;;
  esac
}

detect_arch() {
  case "$(uname -m)" in
    arm64|aarch64) printf aarch64 ;;
    x86_64|amd64) printf x86_64 ;;
    *) abort "unsupported architecture: $(uname -m)" ;;
  esac
}

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# An absent URL refuses rather than skips: a check that cannot read the value it
# gates on is not a check. The quoted variable is a literal prefix to `case`;
# only the trailing * is a wildcard.
require_release_url() {
  field="$1"
  url="$2"

  [ -n "$url" ] || abort "no $field for target $TARGET in $MANIFEST_URL"

  case "$url" in
    "$ARTIFACT_ORIGIN"*) ;;
    *) abort "$field for target $TARGET is not under $ARTIFACT_ORIGIN — refusing to fetch $url" ;;
  esac
}

# cosign-installed and cosign-absent are two valid machine configurations, not
# two code paths for one configuration:
#
#   installed -> the release signature is checked against the pinned workflow
#                identity and OIDC issuer. A FAILED check aborts; nothing is
#                installed and nothing retries by another route.
#   absent    -> one loud line, then continue. This is the bootstrap installer;
#                hard-requiring a Go binary that ships with neither stock macOS
#                nor stock Debian would break the advertised `curl | sh` path
#                for nearly everyone.
#
# The sha256 check above is not a substitute: that digest comes from the same
# releases.json that supplied the URL, so it proves transport integrity and
# nothing whatsoever about authenticity.
verify_signature() {
  blob="$1"

  if ! command -v cosign >/dev/null 2>&1; then
    printf '!!  cosign is not installed: SKIPPING the release signature check on this download. Install cosign (https://docs.sigstore.dev/cosign/system_config/installation/) — "fermix upgrade" and "fermix plugins install" both require it and fail hard without it.\n' >&2
    return 0
  fi

  [ -n "$LATEST_VERSION" ] || abort "no 'latest' version in $MANIFEST_URL"

  printf '==> Verifying signature with cosign...\n'
  curl -fsSL "$ARTIFACT_SIG_URL" -o "${blob}.sig"
  curl -fsSL "$ARTIFACT_CERT_URL" -o "${blob}.pem"

  # --certificate-identity (exact match) rather than the --certificate-identity-regexp
  # form cosign.ex builds: it pins the identical string, but a tampered manifest
  # cannot smuggle regex metacharacters through "latest" to widen the match.
  if ! cosign_out="$(cosign verify-blob \
    --certificate "${blob}.pem" \
    --signature "${blob}.sig" \
    --certificate-identity "${COSIGN_IDENTITY_PREFIX}${LATEST_VERSION}" \
    --certificate-oidc-issuer "$COSIGN_ISSUER" \
    "$blob" 2>&1)"; then
    printf '%s\n' "$cosign_out" >&2
    abort "cosign verify-blob FAILED for $ARTIFACT_NAME — refusing to install"
  fi

  printf '==> Signature verified against %s%s\n' "$COSIGN_IDENTITY_PREFIX" "$LATEST_VERSION"
}

decide_prefix() {
  if [ -n "$PREFIX" ]; then
    printf '%s' "$PREFIX"
    return
  fi

  if [ -w /usr/local/bin ] 2>/dev/null; then
    printf /usr/local/bin
  elif command -v sudo >/dev/null 2>&1 && [ "$(id -u)" -ne 0 ] && [ -d /usr/local/bin ]; then
    printf /usr/local/bin
  else
    mkdir -p "$HOME/.local/bin"
    printf '%s' "$HOME/.local/bin"
  fi
}

install_with_maybe_sudo() {
  src="$1"
  dst="$2"

  if [ -w "$(dirname "$dst")" ] 2>/dev/null; then
    install -m 0755 "$src" "$dst"
  else
    sudo install -m 0755 "$src" "$dst"
  fi
}

OS="$(detect_os)"
ARCH="$(detect_arch)"
TARGET="${OS}-${ARCH}"
ARTIFACT_NAME="fermix_${OS}_${ARCH}"

printf '==> Detected target: %s\n' "$TARGET"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

printf '==> Fetching release manifest...\n'
curl -fsSL "$MANIFEST_URL" -o "$TMPDIR/releases.json"

# Extract URL + sha256 with awk — no jq dependency.
ARTIFACT_URL="$(awk -v t="$TARGET" '
  /"target":/ { gsub(/[",]/,""); current=$2 }
  /"url":/ && current==t { gsub(/[",]/,""); print $2; exit }
' "$TMPDIR/releases.json")"

ARTIFACT_SHA="$(awk -v t="$TARGET" '
  /"target":/ { gsub(/[",]/,""); current=$2 }
  /"sha256":/ && current==t { gsub(/[",]/,""); print $2; exit }
' "$TMPDIR/releases.json")"

ARTIFACT_SIG_URL="$(awk -v t="$TARGET" '
  /"target":/ { gsub(/[",]/,""); current=$2 }
  /"sig_url":/ && current==t { gsub(/[",]/,""); print $2; exit }
' "$TMPDIR/releases.json")"

ARTIFACT_CERT_URL="$(awk -v t="$TARGET" '
  /"target":/ { gsub(/[",]/,""); current=$2 }
  /"cert_url":/ && current==t { gsub(/[",]/,""); print $2; exit }
' "$TMPDIR/releases.json")"

# The manifest carries exactly one release, so "latest" names the tag the
# selected artifact was built and signed under.
LATEST_VERSION="$(awk '
  /"latest":/ { gsub(/[",]/,""); print $2; exit }
' "$TMPDIR/releases.json")"

# All three are pinned here, before the first byte of any of them is fetched.
require_release_url url "$ARTIFACT_URL"
require_release_url sig_url "$ARTIFACT_SIG_URL"
require_release_url cert_url "$ARTIFACT_CERT_URL"

[ -n "$ARTIFACT_SHA" ] || abort "no sha256 for target $TARGET in $MANIFEST_URL"

printf '==> Downloading %s...\n' "$ARTIFACT_NAME"
curl -fsSL "$ARTIFACT_URL" -o "$TMPDIR/$ARTIFACT_NAME"

ACTUAL_SHA="$(sha256 "$TMPDIR/$ARTIFACT_NAME")"
if [ "$ACTUAL_SHA" != "$ARTIFACT_SHA" ]; then
  abort "sha256 mismatch: expected $ARTIFACT_SHA, got $ACTUAL_SHA"
fi
printf '==> Verified sha256 %s\n' "$ACTUAL_SHA"

verify_signature "$TMPDIR/$ARTIFACT_NAME"

INSTALL_PREFIX="$(decide_prefix)"
INSTALL_PATH="$INSTALL_PREFIX/fermix"

printf '==> Installing to %s\n' "$INSTALL_PATH"
install_with_maybe_sudo "$TMPDIR/$ARTIFACT_NAME" "$INSTALL_PATH"

if ! command -v fermix >/dev/null 2>&1; then
  printf '\nNote: %s is not on $PATH.\n' "$INSTALL_PREFIX"
  printf 'Add it with:\n'
  printf '  export PATH="%s:$PATH"\n' "$INSTALL_PREFIX"
fi

if [ "$RUN_SETUP" -eq 1 ]; then
  printf '\n==> Running fermix setup\n'
  "$INSTALL_PATH" setup
else
  printf '\nSkipping fermix setup (--no-setup). Run manually with: fermix setup\n'
fi

printf '\nDone. fermix is installed at %s.\n' "$INSTALL_PATH"
