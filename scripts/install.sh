#!/usr/bin/env sh
# fermix installer.
#
# Detects (os, arch), downloads the matching signed binary from the
# latest GitHub Release, sha256-verifies it against releases.json,
# and drops it in /usr/local/bin (with sudo) or ~/.local/bin (no
# sudo) depending on what's writable. Optionally runs `fermix setup`
# at the end.
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
require_cmd shasum 2>/dev/null || require_cmd sha256sum
require_cmd uname
require_cmd mkdir
require_cmd install
require_cmd mktemp

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

[ -n "$ARTIFACT_URL" ] || abort "no artifact for target $TARGET in $MANIFEST_URL"
[ -n "$ARTIFACT_SHA" ] || abort "no sha256 for target $TARGET in $MANIFEST_URL"

printf '==> Downloading %s...\n' "$ARTIFACT_NAME"
curl -fsSL "$ARTIFACT_URL" -o "$TMPDIR/$ARTIFACT_NAME"

ACTUAL_SHA="$(sha256 "$TMPDIR/$ARTIFACT_NAME")"
if [ "$ACTUAL_SHA" != "$ARTIFACT_SHA" ]; then
  abort "sha256 mismatch: expected $ARTIFACT_SHA, got $ACTUAL_SHA"
fi
printf '==> Verified sha256 %s\n' "$ACTUAL_SHA"

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
