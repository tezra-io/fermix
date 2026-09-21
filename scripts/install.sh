#!/usr/bin/env sh
# fermix installer.
#
# On Linux with apt, dnf or zypper it installs the latest release's signed
# .deb or .rpm package through that package manager. On macOS, on a Linux host
# with none of the three, or with --standalone, it installs the signed
# standalone binary instead, in /usr/local/bin (with sudo) or ~/.local/bin (no
# sudo) depending on what's writable. Either way the download is
# sha256-verified against releases.json and cosign-verified when cosign is
# installed, and `fermix setup` runs at the end unless told not to.
#
#   curl -fsSL https://fermix.ai/install | sh
#   curl -fsSL https://fermix.ai/install | sh -s -- --no-setup
#   curl -fsSL https://fermix.ai/install | sh -s -- --standalone --prefix /opt/fermix/bin
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
STANDALONE=0

# Where the package puts the engine, and the cosign it bundles beside it.
PACKAGE_BINARY="/usr/bin/fermix"
PACKAGE_COSIGN="/usr/lib/fermix/cosign"
MIGRATE_URL="https://fermix.ai/docs/linux-packages#move-from-a-standalone-install"
VERIFY_URL="https://fermix.ai/docs/linux-packages#download-and-verify"

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
Usage: install.sh [--standalone] [--prefix DIR] [--no-setup]

On Linux with apt, dnf or zypper this installs the fermix .deb or .rpm package.
Everywhere else, and with --standalone, it installs the standalone binary.

Options:
  --standalone   Install the standalone binary even where a package would be used
  --prefix DIR   Install location for the standalone binary
                 (default: /usr/local/bin if writable or sudo, else ~/.local/bin)
  --no-setup     Skip 'fermix setup' at the end
  --help, -h     Show this message
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX="${2:?--prefix requires a value}"; shift 2 ;;
    --no-setup) RUN_SETUP=0; shift ;;
    --standalone) STANDALONE=1; shift ;;
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
require_cmd awk
require_cmd mkdir
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

# Which package manager installs the package here, or nothing when this machine
# gets the standalone binary. These are configurations of the machine, not a
# chain of attempts: the answer is fixed before anything is downloaded, and a
# package install that fails never turns into a standalone one.
detect_package_manager() {
  [ "$OS" = linux ] || return 0
  [ "$STANDALONE" -eq 0 ] || return 0

  if command -v dpkg >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
    printf apt
  elif command -v rpm >/dev/null 2>&1 && command -v dnf >/dev/null 2>&1; then
    printf dnf
  elif command -v rpm >/dev/null 2>&1 && command -v zypper >/dev/null 2>&1; then
    printf zypper
  fi
}

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# One field of this machine's package, read from the manifest's "packages"
# object: packages -> <target> -> <deb|rpm> -> <field>. The same line scanner
# the artifact fields below use, so there is still no jq dependency; it relies
# on the one-key-per-line layout scripts/release/build_releases_json.sh emits.
package_field() {
  awk -v target="$TARGET" -v format="$PACKAGE_FORMAT" -v field="$1" '
    { gsub(/[",]/, "") }
    $1 == "packages:" { in_packages = 1; next }
    !in_packages { next }
    $2 == "{" {
      key = $1
      sub(/:$/, "", key)
      if (key == "deb" || key == "rpm") { current_format = key }
      else { current_target = key; current_format = "" }
      next
    }
    current_target == target && current_format == format && $1 == (field ":") { print $2; exit }
  ' "$TMPDIR/releases.json"
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

# A cosign on PATH wins; failing that, the one an installed fermix package
# bundles, which is the order the packaged engine itself resolves it in. So a
# package install that is being updated always has its download checked.
find_cosign() {
  if command -v cosign >/dev/null 2>&1; then
    command -v cosign
  elif [ -x "$PACKAGE_COSIGN" ]; then
    printf '%s' "$PACKAGE_COSIGN"
  fi
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
  cosign_bin="$(find_cosign)"

  if [ -z "$cosign_bin" ]; then
    if [ -n "$PACKAGE_MANAGER" ]; then
      printf '!!  cosign is not installed: SKIPPING the release signature check on this download. To check the signature yourself before installing, see %s\n' "$VERIFY_URL" >&2
    else
      printf '!!  cosign is not installed: SKIPPING the release signature check on this download. Install cosign (https://docs.sigstore.dev/cosign/system_config/installation/) — "fermix upgrade" and "fermix plugins install" both require it and fail hard without it.\n' >&2
    fi
    return 0
  fi

  [ -n "$LATEST_VERSION" ] || abort "no 'latest' version in $MANIFEST_URL"

  printf '==> Verifying signature with cosign...\n'
  curl -fsSL "$ARTIFACT_SIG_URL" -o "${blob}.sig"
  curl -fsSL "$ARTIFACT_CERT_URL" -o "${blob}.pem"

  # --certificate-identity (exact match) rather than the --certificate-identity-regexp
  # form cosign.ex builds: it pins the identical string, but a tampered manifest
  # cannot smuggle regex metacharacters through "latest" to widen the match.
  if ! cosign_out="$("$cosign_bin" verify-blob \
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

# A system package is installed by root. Its input is /dev/null because under
# `curl | sh` standard input is this script, and a package manager that read it
# would swallow the lines still to run; sudo asks for a password on the
# terminal, not on standard input.
run_as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@" </dev/null
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@" </dev/null
  else
    abort "installing the package needs root, and this account has no sudo. Run the installer as root, or pass --standalone for a binary that needs none."
  fi
}

# The version of the fermix package this machine already has, or nothing. Both
# databases are asked whether it is installed before they are asked which: dpkg
# still reports a version for a removed package whose state it remembers, and
# rpm answers "package fermix is not installed" on standard output.
installed_package_version() {
  case "$PACKAGE_FORMAT" in
    deb)
      # shellcheck disable=SC2016 # ${...} is dpkg-query's own format syntax
      dpkg-query -W -f='${db:Status-Status} ${Version}\n' fermix 2>/dev/null |
        awk '$1 == "installed" { print $2 }'
      ;;
    rpm)
      if rpm -q fermix >/dev/null 2>&1; then
        rpm -q --qf '%{VERSION}' fermix
      fi
      ;;
  esac
}

install_package() {
  file="$1"

  case "$PACKAGE_MANAGER" in
    apt) run_as_root apt-get install -y "$file" ;;
    dnf) run_as_root dnf install -y "$file" ;;
    # The rpm carries no GPG signature of its own; the sha256 and cosign checks
    # above are what vouched for this file, so zypper is told not to stop on it.
    zypper) run_as_root zypper --non-interactive install --allow-unsigned-rpm "$file" ;;
  esac

  [ -x "$PACKAGE_BINARY" ] ||
    abort "$PACKAGE_MANAGER reported success, but $PACKAGE_BINARY is not there"
}

# The wizard reads its answers from standard input, which under `curl | sh` is
# this script. With a terminal to hand it, setup gets the terminal; with none
# (a CI job, a container without -t) there is nobody to answer, so the next
# command is printed instead of started.
run_setup() {
  binary="$1"

  if [ -t 0 ]; then
    "$binary" setup || setup_did_not_finish
  elif (: </dev/tty) 2>/dev/null; then
    "$binary" setup </dev/tty || setup_did_not_finish
  else
    printf '\nNo terminal is attached, so setup was not started. Run it yourself: fermix setup\n'
  fi
}

setup_did_not_finish() {
  abort "fermix is installed, but 'fermix setup' did not finish. Run it again when you are ready: fermix setup"
}

OS="$(detect_os)"
ARCH="$(detect_arch)"
TARGET="${OS}-${ARCH}"
PACKAGE_MANAGER="$(detect_package_manager)"

case "$PACKAGE_MANAGER" in
  apt) PACKAGE_FORMAT=deb ;;
  dnf|zypper) PACKAGE_FORMAT=rpm ;;
  *) PACKAGE_FORMAT="" ;;
esac

if [ -n "$PACKAGE_MANAGER" ]; then
  [ -z "$PREFIX" ] ||
    abort "--prefix places the standalone binary, and $PACKAGE_MANAGER installs the package to $PACKAGE_BINARY. Pass --standalone with --prefix, or drop --prefix."
  ARTIFACT_NAME="fermix.${PACKAGE_FORMAT}"
  printf '==> Detected target: %s (%s package, installed with %s)\n' "$TARGET" "$PACKAGE_FORMAT" "$PACKAGE_MANAGER"
else
  require_cmd install
  ARTIFACT_NAME="fermix_${OS}_${ARCH}"
  printf '==> Detected target: %s (standalone binary)\n' "$TARGET"
  if [ "$OS" = linux ] && [ "$STANDALONE" -eq 0 ]; then
    printf '==> No apt, dnf or zypper on this machine, so this installs the standalone binary. It updates itself with: fermix upgrade\n'
  fi
fi

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

printf '==> Fetching release manifest...\n'
curl -fsSL "$MANIFEST_URL" -o "$TMPDIR/releases.json"

# The manifest carries exactly one release, so "latest" names the tag the
# selected artifact was built and signed under.
LATEST_VERSION="$(awk '
  /"latest":/ { gsub(/[",]/,""); print $2; exit }
' "$TMPDIR/releases.json")"

if [ -n "$PACKAGE_MANAGER" ]; then
  ARTIFACT_URL="$(package_field url)"
  ARTIFACT_SHA="$(package_field sha256)"
  ARTIFACT_SIG_URL="$(package_field sig_url)"
  ARTIFACT_CERT_URL="$(package_field cert_url)"

  [ -n "$ARTIFACT_URL" ] ||
    abort "release ${LATEST_VERSION:-unknown} lists no $PACKAGE_FORMAT package for $TARGET in $MANIFEST_URL. Pass --standalone to install the standalone binary instead."
else
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
fi

# All three are pinned here, before the first byte of any of them is fetched.
require_release_url url "$ARTIFACT_URL"
require_release_url sig_url "$ARTIFACT_SIG_URL"
require_release_url cert_url "$ARTIFACT_CERT_URL"

[ -n "$ARTIFACT_SHA" ] || abort "no sha256 for target $TARGET in $MANIFEST_URL"

PREVIOUS_VERSION=""
if [ -n "$PACKAGE_MANAGER" ]; then
  [ -n "$LATEST_VERSION" ] || abort "no 'latest' version in $MANIFEST_URL"
  PREVIOUS_VERSION="$(installed_package_version)"

  if [ "$PREVIOUS_VERSION" = "$LATEST_VERSION" ]; then
    printf '\nfermix %s is already installed, and it is the latest release. If this account has not set it up yet, run: fermix setup\n' "$LATEST_VERSION"
    exit 0
  fi
fi

printf '==> Downloading %s...\n' "$(basename "$ARTIFACT_URL")"
curl -fsSL "$ARTIFACT_URL" -o "$TMPDIR/$ARTIFACT_NAME"

ACTUAL_SHA="$(sha256 "$TMPDIR/$ARTIFACT_NAME")"
if [ "$ACTUAL_SHA" != "$ARTIFACT_SHA" ]; then
  abort "sha256 mismatch: expected $ARTIFACT_SHA, got $ACTUAL_SHA"
fi
printf '==> Verified sha256 %s\n' "$ACTUAL_SHA"

verify_signature "$TMPDIR/$ARTIFACT_NAME"

if [ -n "$PACKAGE_MANAGER" ]; then
  # apt reads a local package as its own unprivileged user, which cannot enter
  # the 0700 directory mktemp made.
  chmod 0755 "$TMPDIR"
  chmod 0644 "$TMPDIR/$ARTIFACT_NAME"

  printf '==> Installing the package with %s\n' "$PACKAGE_MANAGER"
  install_package "$TMPDIR/$ARTIFACT_NAME"
  INSTALL_PATH="$PACKAGE_BINARY"
else
  INSTALL_PREFIX="$(decide_prefix)"
  INSTALL_PATH="$INSTALL_PREFIX/fermix"

  printf '==> Installing to %s\n' "$INSTALL_PATH"
  install_with_maybe_sudo "$TMPDIR/$ARTIFACT_NAME" "$INSTALL_PATH"

  if ! command -v fermix >/dev/null 2>&1; then
    printf '\nNote: %s is not on $PATH.\n' "$INSTALL_PREFIX"
    printf 'Add it with:\n'
    printf '  export PATH="%s:$PATH"\n' "$INSTALL_PREFIX"
  fi
fi

# What this account's shell runs when it types `fermix`. An earlier standalone
# install sits earlier on PATH than /usr/bin, and its service keeps running, so
# starting setup here would configure the wrong engine. The two are compared as
# files, not as spellings: on a merged-/usr host /bin/fermix is the package's.
ON_PATH="$(command -v fermix 2>/dev/null || true)"

if [ -n "$PACKAGE_MANAGER" ] && [ -n "$ON_PATH" ] && ! [ "$ON_PATH" -ef "$PACKAGE_BINARY" ]; then
  printf '\nThe package is installed at %s, but typing fermix on this account runs %s, an earlier install.\n' "$PACKAGE_BINARY" "$ON_PATH"
  printf 'Move that install to the package before running setup: %s\n' "$MIGRATE_URL"
elif [ -n "$PREVIOUS_VERSION" ]; then
  printf '\nUpdated fermix %s to %s. A running service keeps the old engine until you run: fermix restart\n' "$PREVIOUS_VERSION" "$LATEST_VERSION"
elif [ "$RUN_SETUP" -eq 0 ]; then
  printf '\nSkipping fermix setup (--no-setup). Run manually with: fermix setup\n'
elif [ -n "$PACKAGE_MANAGER" ] && [ -n "${SUDO_USER:-}" ]; then
  # The service belongs to the account that sets it up, and under sudo that
  # account would be root.
  printf '\nThe background service belongs to the account that sets it up. Run setup as %s, without sudo: fermix setup\n' "$SUDO_USER"
else
  printf '\n==> Running fermix setup\n'
  run_setup "$INSTALL_PATH"
fi

printf '\nDone. fermix is installed at %s.\n' "$INSTALL_PATH"
