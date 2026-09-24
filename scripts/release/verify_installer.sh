#!/usr/bin/env bash
# Run the advertised installer against the release that was just published, and
# prove that what it installed is that release.
#
# This is the one check that cannot run on a draft: scripts/install.sh reads
# releases/latest/download/releases.json and downloads from the public release
# URLs, and neither answers until the release is published. So it runs after
# promotion, beside the Homebrew check, and a failure here means the command
# the site advertises is broken for a release people can already see.
#
# The deb row installs on the runner itself, through sudo, the way a person's
# machine does. The rpm row installs inside a Fedora container as root, with
# the runner's cosign mounted in so the signature check runs there too rather
# than being skipped.

set -euo pipefail

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

usage() {
  printf 'usage: %s <deb|rpm> <version>\n' "$0" >&2
  exit 2
}

[ "$#" -eq 2 ] || usage

kind="$1"
version="$2"

case "$kind" in
  deb | rpm) ;;
  *) fail "unsupported package kind: $kind" ;;
esac
[ -n "$version" ] || fail "expected version must not be empty"

repo_root="$(cd "$(dirname "$0")/../.." && pwd -P)"
installer="$repo_root/scripts/install.sh"
[ -f "$installer" ] || fail "installer not found: $installer"

feed_url="https://github.com/tezra-io/fermix/releases/latest/download/releases.json"
identity="https://github.com/tezra-io/fermix/.github/workflows/release.yml@refs/tags/v${version}"

cosign_path="$(command -v cosign)" ||
  fail "cosign is required, so the installer checks the signature instead of skipping it"

# Publication and the `latest` redirect are not one atomic step. The wait is
# bounded, and running out of checks is a failure that names what the feed said.
feed_latest=""
for attempt in $(seq 1 12); do
  feed="$(curl -fsSL "$feed_url")" || feed=""
  feed_latest="$(python3 -c '
import json, sys
try:
    print(json.loads(sys.argv[1]).get("latest", ""))
except ValueError:
    print("")
' "$feed")"
  [ "$feed_latest" = "$version" ] && break
  [ "$attempt" -eq 12 ] || sleep 10
done
if [ "$feed_latest" != "$version" ]; then
  [ -n "$feed" ] || fail "the latest release feed could not be fetched from $feed_url in 12 checks"
  fail "the latest release feed still names '${feed_latest}' instead of $version after 12 checks"
fi

# What every row asserts about the installer's own words.
check_transcript() {
  transcript="$1"

  case "$transcript" in
    *"($kind package, installed with "*) ;;
    *) fail "the installer did not choose the $kind package on this host" ;;
  esac
  case "$transcript" in
    *"Signature verified against $identity"*) ;;
    *) fail "the installer did not verify the package signature against $identity" ;;
  esac
}

if [ "$kind" = rpm ]; then
  command -v docker >/dev/null 2>&1 || fail "docker is required to run the rpm row"

  transcript="$(
    docker run --rm \
      -v "$installer":/install.sh:ro \
      -v "$cosign_path":/usr/local/bin/cosign:ro \
      fedora:41 sh -c '
        set -eu
        sh /install.sh --no-setup
        printf "installed-version=%s\n" "$(rpm -q --qf "%{VERSION}" fermix)"
        printf "engine-version=%s\n" "$(fermix --version)"
      ' 2>&1
  )" || {
    printf '%s\n' "$transcript"
    fail "the installer did not finish inside fedora:41"
  }
  printf '%s\n' "$transcript"

  check_transcript "$transcript"
  case "$transcript" in
    *"installed-version=${version}"$'\n'*) ;;
    *) fail "rpm does not report fermix $version installed" ;;
  esac
  case "$transcript" in
    *"engine-version="*"$version"*) ;;
    *) fail "fermix --version inside the container did not contain $version" ;;
  esac

  exit 0
fi

transcript="$(sh "$installer" --no-setup 2>&1)" || {
  printf '%s\n' "$transcript"
  fail "the installer did not finish on this runner"
}
printf '%s\n' "$transcript"
check_transcript "$transcript"

# shellcheck disable=SC2016 # ${Version} is dpkg-query's own format syntax
installed="$(dpkg-query -W -f='${Version}' fermix)"
[ "$installed" = "$version" ] || fail "dpkg reports fermix $installed installed, not $version"

engine="$(fermix --version)"
printf '%s\n' "$engine"
case "$engine" in
  *"$version"*) ;;
  *) fail "fermix --version does not contain $version" ;;
esac

# Running it again is how a person updates, so a machine already on the latest
# release must be left alone rather than reinstalled.
again="$(sh "$installer" --no-setup 2>&1)" || {
  printf '%s\n' "$again"
  fail "the installer refused a machine that already has $version"
}
printf '%s\n' "$again"
case "$again" in
  *"fermix $version is already installed"*) ;;
  *) fail "a second run did not recognise the installed $version" ;;
esac
