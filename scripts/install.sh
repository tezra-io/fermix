#!/usr/bin/env sh
# fermix installer.
#
# On Linux with apt, dnf or zypper it installs the latest release's signed
# .deb or .rpm package through that package manager. On macOS, on a Linux host
# with none of the three, or with --standalone, it installs the signed
# standalone binary instead, in /usr/local/bin (with sudo) or ~/.local/bin (no
# sudo) depending on what's writable. Either way the download must match the
# sha256 that fermix.ai lists for it, and `fermix setup` runs at the end unless
# told not to. --version X installs release X instead, under the same check,
# and a package of X already installed is left as it is.
#
# --always-on sets a Linux server up as an owner's Always On server instead:
# it fetches the release's Always On server script (the copy of
# packaging/cloud/first-boot.sh every release publishes as
# fermix_always_on.sh), checks it as it checks a package, and runs it with
# --version naming that release, every other argument passed on unread. The
# server then runs exactly its desktop's release: its first boot and its
# updates, every five minutes and nightly, ask this installer for it.
#
# Where the trust comes from. The files are downloaded from the project's
# GitHub release, but their digests are not: they are read from the table at
# https://fermix.ai/install/releases, which the site publishes only after it
# has checked each file's cosign signature against the release workflow's
# identity for that tag and hashed the file itself. A compromised release
# channel can replace a file, its signature and GitHub's own manifest
# together; it cannot change the digest this script compares with. So there
# is no cosign to find and no check to skip: a file the table does not list,
# or one that does not match it, the Always On server script included, is
# refused before anything runs as root.
#
#   curl -fsSL https://fermix.ai/install | sh
#   curl -fsSL https://fermix.ai/install | sh -s -- --no-setup
#   curl -fsSL https://fermix.ai/install | sh -s -- --standalone --prefix /opt/fermix/bin
#   curl -fsSL https://fermix.ai/install | sh -s -- --version 0.17.0
#   curl -fsSL https://fermix.ai/install | sudo sh -s -- --always-on --version 0.19.0
#
# Hard-fails on any unsupported (os, arch) pair, missing tooling, a digest
# table it cannot read or that lists no row for this machine's file, or a
# sha256 mismatch. There is no "best effort" path that drops a half-installed
# binary somewhere — partial installs make `fermix upgrade` and `fermix
# doctor` lie about reality.

set -eu

REPO="tezra-io/fermix"
DIGESTS_URL="https://fermix.ai/install/releases"
VERSION=""
VERSION_GIVEN=0
RUN_SETUP=1
PREFIX=""
STANDALONE=0
ALWAYS_ON=0
# The option still waiting for its value while the arguments are read.
VALUE_FOR=""

# Where the package puts the engine.
PACKAGE_BINARY="/usr/bin/fermix"
MIGRATE_URL="https://fermix.ai/docs/linux-packages#move-from-a-standalone-install"
VERIFY_URL="https://fermix.ai/docs/linux-packages#download-and-verify"
# The release's Always On server script, a byte copy of
# packaging/cloud/first-boot.sh that every release publishes and signs.
ALWAYS_ON_FILE="fermix_always_on.sh"

# Every artifact is downloaded from ${ARTIFACT_ORIGIN}v<version>/<file>, the
# base that @artifact_origin in apps/fermix_core/lib/fermix/cli/upgrade/manifest.ex
# pins for `fermix upgrade`. The address is built here from the release and the
# file name, never read from a document, so nothing can point this machine
# anywhere else.
ARTIFACT_ORIGIN="https://github.com/${REPO}/releases/download/"

usage() {
  cat <<USAGE
Usage: install.sh [--standalone] [--prefix DIR] [--version X] [--no-setup]
       install.sh --always-on [--version X] [SERVER OPTIONS]

On Linux with apt, dnf or zypper this installs the fermix .deb or .rpm package.
Everywhere else, and with --standalone, it installs the standalone binary.

Options:
  --standalone   Install the standalone binary even where a package would be used
  --prefix DIR   Install location for the standalone binary
                 (default: /usr/local/bin if writable or sudo, else ~/.local/bin)
  --version X    Install release X (such as 0.17.0) instead of the latest
  --no-setup     Skip 'fermix setup' at the end
  --always-on    Set this server up for Always On with release X's own server
                 script, run as root; SERVER OPTIONS are that script's
  --help, -h     Show this message
USAGE
}

prefix_needs_a_value() {
  printf 'install.sh: --prefix requires a value\n' >&2
  exit 2
}

# The mode comes first, so that without --always-on an argument this installer
# does not own is refused where it stands, as it always was.
for argument do
  [ "$argument" != --always-on ] || ALWAYS_ON=1
done

# Each argument is shifted off as it is read. With --always-on, one this
# installer does not own goes back on the end, so "$@" holds only those once
# the loop is done. They are the Always On server script's to read and are
# never echoed, since one may be an enrollment code pasted in the wrong place.
for argument do
  shift
  case "$VALUE_FOR" in
    --prefix) [ -n "$argument" ] || prefix_needs_a_value; PREFIX="$argument"; VALUE_FOR=""; continue ;;
    --version) VERSION="$argument"; VALUE_FOR=""; continue ;;
  esac
  case "$argument" in
    --prefix) VALUE_FOR=--prefix ;;
    --no-setup) RUN_SETUP=0 ;;
    --standalone) STANDALONE=1 ;;
    --version) VERSION_GIVEN=1; VALUE_FOR=--version ;;
    --always-on) ;;
    --help|-h) usage; exit 0 ;;
    *)
      [ "$ALWAYS_ON" -eq 1 ] || { echo "install.sh: unknown argument: $argument" >&2; usage; exit 2; }
      set -- "$@" "$argument"
      ;;
  esac
done

[ "$VALUE_FOR" != --prefix ] || prefix_needs_a_value

abort() {
  printf 'install.sh: %s\n' "$*" >&2
  exit 1
}

# Whether $1 is a release as every release's packages are versioned: a plain
# MAJOR.MINOR.PATCH, digits and exactly two dots.
release_version() {
  case "$1" in
    "" | *[!0-9.]* | .* | *. | *..*) return 1 ;;
  esac
  minor_patch=${1#*.}
  patch=${minor_patch#*.}
  case "$patch" in *.*) return 1 ;; esac
  [ "$minor_patch" != "$1" ] && [ "$patch" != "$minor_patch" ]
}

if [ "$VERSION_GIVEN" -eq 1 ] && ! release_version "$VERSION"; then
  printf 'install.sh: --version takes a release, such as 0.17.0\n' >&2
  usage >&2
  exit 2
fi

if [ "$ALWAYS_ON" -eq 1 ] && { [ "$STANDALONE" -eq 1 ] || [ -n "$PREFIX" ] || [ "$RUN_SETUP" -eq 0 ]; }; then
  printf "install.sh: --always-on runs the release's Always On server script, which installs Fermix itself, so it takes none of --standalone, --prefix and --no-setup.\n" >&2
  exit 2
fi

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

# The release's own name for the file this machine installs, as the release
# workflow builds it: the standalone binary is named for its target, a deb for
# Debian's architecture name, and an rpm carries nFPM's default release "1".
artifact_file() {
  case "$PACKAGE_FORMAT" in
    deb)
      case "$ARCH" in
        x86_64) printf 'fermix_%s_amd64.deb' "$VERSION" ;;
        aarch64) printf 'fermix_%s_arm64.deb' "$VERSION" ;;
      esac
      ;;
    rpm) printf 'fermix-%s-1.%s.rpm' "$VERSION" "$ARCH" ;;
    *) printf 'fermix_%s_%s' "$OS" "$ARCH" ;;
  esac
}

# The table is plain lines, read with awk alone:
#
#   format 1
#   latest <version>
#   <version> <sha256> <file>      (one line per file of every listed release)
#
# A first line other than "format 1" is a table this script cannot read, and is
# refused rather than guessed at.
table_format() {
  awk 'NR == 1 { print; exit }' "$TMPDIR/releases"
}

table_latest() {
  awk 'NR > 1 && NF == 2 && $1 == "latest" { print $2; exit }' "$TMPDIR/releases"
}

table_lists_release() {
  awk -v version="$1" '
    NR > 1 && NF == 3 && $1 == version { found = 1; exit }
    END { exit !found }
  ' "$TMPDIR/releases"
}

# The sha256 the table lists for file $2 of release $1, or nothing unless it
# lists exactly one: a file listed twice is no more trustworthy than a file
# not listed at all.
table_digest() {
  awk -v version="$1" -v file="$2" '
    NR > 1 && NF == 3 && $1 == version && $3 == file { digest = $2; rows++ }
    END { if (rows == 1) print digest }
  ' "$TMPDIR/releases"
}

# Whether $1 is a sha256 as the table writes one: 64 lowercase hex digits.
sha256_hex() {
  case "$1" in *[!0-9a-f]*) return 1 ;; esac
  [ "${#1}" -eq 64 ]
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

  # Nothing else on the machine is removed to make room: a package that
  # depends on the exact engine version already installed, as the desktop
  # companion does, stops the install with apt's own words rather than being
  # taken away silently. dnf refuses that case by default.
  case "$PACKAGE_MANAGER" in
    apt) run_as_root apt-get install -y --no-remove "$file" ;;
    dnf) run_as_root dnf install -y "$file" ;;
    # The rpm carries no GPG signature of its own. What vouched for this file is
    # the sha256 above, which matched the digest fermix.ai lists for it, so
    # zypper is told not to stop on the missing GPG signature.
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

# Fetches the digest table into a directory of this run's own, removed on
# exit, and settles VERSION: the release --version named, or the table's
# latest, which the table must list.
read_table() {
  TMPDIR="$(mktemp -d)"
  trap 'rm -rf "$TMPDIR"' EXIT

  printf '==> Fetching release digests from %s...\n' "$DIGESTS_URL"
  curl -fsSL "$DIGESTS_URL" -o "$TMPDIR/releases" ||
    abort "could not fetch the release digests from $DIGESTS_URL, so nothing was installed. Check this machine's connection to fermix.ai and run the installer again."

  [ "$(table_format)" = "format 1" ] ||
    abort "$DIGESTS_URL is not in a format this installer reads (its first line is '$(table_format)'), so nothing was installed. Fetch the installer again from https://fermix.ai/install."

  LATEST_VERSION="$(table_latest)"
  release_version "$LATEST_VERSION" ||
    abort "$DIGESTS_URL names no latest release, so nothing was installed."

  [ "$VERSION_GIVEN" -eq 1 ] || VERSION="$LATEST_VERSION"

  table_lists_release "$VERSION" ||
    abort "$DIGESTS_URL lists no release $VERSION, so nothing was installed. A release is listed once its signatures have been verified; to check one by hand, see $VERIFY_URL"
}

# Downloads file $1 of the release into $2 and refuses it unless its sha256 is
# $3, the digest the table lists for it.
download_checked() {
  printf '==> Downloading %s...\n' "$1"
  curl -fsSL "${ARTIFACT_ORIGIN}v${VERSION}/$1" -o "$2"

  actual_sha="$(sha256 "$2")"
  if [ "$actual_sha" != "$3" ]; then
    abort "sha256 mismatch: expected $3, got $actual_sha. The download is not the file $DIGESTS_URL lists for release $VERSION, so nothing was installed."
  fi
  printf '==> Verified sha256 %s against %s (%s, release %s)\n' "$actual_sha" "$DIGESTS_URL" "$1" "$VERSION"
}

# --always-on: the release's Always On server script, checked as a package is,
# runs with that release named first and then every argument this installer
# does not own, unchanged, and the installer ends with its exit status. The
# host checks (root, the system, the architecture, Landlock) are the script's
# alone. Its input is /dev/null, as a package manager's is, because under
# `curl | sh` standard input is the rest of this script; it asks for the
# enrollment code and the Tailscale auth key on the terminal itself, and
# inherits them from the environment (FERMIX_ENROLL_CODE, TS_AUTHKEY) under
# cloud-init. An interrupt waits for the script to stop, then removes the
# download with the rest of this run's directory.
run_always_on() {
  trap 'exit 130' INT
  trap 'exit 143' TERM
  read_table

  script_sha="$(table_digest "$VERSION" "$ALWAYS_ON_FILE")"
  sha256_hex "$script_sha" ||
    abort "$DIGESTS_URL lists no Always On server script for release $VERSION, so nothing was run."
  download_checked "$ALWAYS_ON_FILE" "$TMPDIR/$ALWAYS_ON_FILE" "$script_sha"

  printf '==> Running the Always On server script of release %s\n' "$VERSION"
  status=0
  sh "$TMPDIR/$ALWAYS_ON_FILE" --version "$VERSION" "$@" </dev/null || status=$?
  exit "$status"
}

[ "$ALWAYS_ON" -eq 0 ] || run_always_on "$@"

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

read_table

ARTIFACT_FILE="$(artifact_file)"
ARTIFACT_SHA="$(table_digest "$VERSION" "$ARTIFACT_FILE")"

if ! sha256_hex "$ARTIFACT_SHA"; then
  standalone_hint=""
  [ -z "$PACKAGE_MANAGER" ] || standalone_hint=" Pass --standalone to install the standalone binary instead."
  abort "$DIGESTS_URL lists no single sha256 for $ARTIFACT_FILE of release $VERSION, so nothing was installed.$standalone_hint"
fi

PREVIOUS_VERSION=""
if [ -n "$PACKAGE_MANAGER" ]; then
  PREVIOUS_VERSION="$(installed_package_version)"

  if [ "$PREVIOUS_VERSION" = "$VERSION" ] && [ "$VERSION_GIVEN" -eq 1 ]; then
    printf '\nfermix %s is already installed.\n' "$VERSION"
    exit 0
  elif [ "$PREVIOUS_VERSION" = "$VERSION" ]; then
    printf '\nfermix %s is already installed, and it is the latest release. If this account has not set it up yet, run: fermix setup\n' "$VERSION"
    exit 0
  fi
fi

download_checked "$ARTIFACT_FILE" "$TMPDIR/$ARTIFACT_NAME" "$ARTIFACT_SHA"

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
  printf '\nUpdated fermix %s to %s. A running service keeps the old engine until you run: fermix restart\n' "$PREVIOUS_VERSION" "$VERSION"
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
