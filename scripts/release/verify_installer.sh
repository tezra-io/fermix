#!/usr/bin/env bash
# Run the repository's installer against the release that was just published, and
# prove that what it installed is that release.
#
# This is the one check that cannot run on a draft: scripts/install.sh downloads
# from the release's public URLs, which answer only once the release is
# published. So it runs after promotion, beside the Homebrew check.
#
# The installer trusts nothing but the digest table https://fermix.ai/install/releases
# serves, and the site lists a release only once its own pin of that release has
# deployed, which comes after the release. So the installer is handed the table
# the rail built from its own cosign-verified files (build_install_table.sh): a
# curl stand-in first on its PATH answers that one address from the rail's
# table, and every other address, the release files included, goes to the real
# curl. What the site then serves is checked by hand once it deploys
# (docs/RELEASING.md).
#
# The deb row installs on the runner itself, through sudo, the way a person's
# machine does. The rpm row installs inside a Fedora container as root, with
# the same stand-in in front of the container's own curl.

set -euo pipefail

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

usage() {
  printf 'usage: %s <deb|rpm> <version> <digest-table>\n' "$0" >&2
  exit 2
}

[ "$#" -eq 3 ] || usage

kind="$1"
version="$2"
table="$3"

case "$kind" in
  deb | rpm) ;;
  *) fail "unsupported package kind: $kind" ;;
esac
[ -n "$version" ] || fail "expected version must not be empty"
[ -f "$table" ] || fail "digest table not found: $table"
{ read -r format_line && read -r latest_line; } <"$table" || fail "the digest table at $table has fewer than two lines"
[ "$format_line" = "format 1" ] && [ "$latest_line" = "latest $version" ] ||
  fail "the digest table at $table does not open with 'format 1' and 'latest $version'"

repo_root="$(cd "$(dirname "$0")/../.." && pwd -P)"
installer="$repo_root/scripts/install.sh"
[ -f "$installer" ] || fail "installer not found: $installer"

table_url="https://fermix.ai/install/releases"

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

# write_curl_stand_in <path> <the table, as the stand-in sees it> <the real curl>
write_curl_stand_in() {
  cat >"$1" <<STAND_IN
#!/bin/sh
# The release rail's stand-in for curl: $table_url is answered from the
# rail's own table, and every other address goes to $3.
output=""
previous=""
asks_for_table=0
for argument in "\$@"; do
  [ "\$previous" != "-o" ] || output="\$argument"
  [ "\$argument" != "$table_url" ] || asks_for_table=1
  previous="\$argument"
done
if [ "\$asks_for_table" -eq 1 ]; then
  [ -n "\$output" ] || { echo "curl stand-in: $table_url was asked for without -o" >&2; exit 2; }
  exec cp "$2" "\$output"
fi
exec "$3" "\$@"
STAND_IN
  chmod 0755 "$1"
}

# What every row asserts about the installer's own words.
check_transcript() {
  transcript="$1"

  case "$transcript" in
    *"($kind package, installed with "*) ;;
    *) fail "the installer did not choose the $kind package on this host" ;;
  esac
  case "$transcript" in
    *"==> Verified sha256 "*" against $table_url ("*", release $version)"*) ;;
    *) fail "the installer did not check the $kind package against the digest $table_url lists for $version" ;;
  esac
}

if [ "$kind" = rpm ]; then
  command -v docker >/dev/null 2>&1 || fail "docker is required to run the rpm row"
  write_curl_stand_in "$work/container-curl" /fermix-install-releases /usr/bin/curl

  transcript="$(
    docker run --rm \
      -v "$installer":/install.sh:ro \
      -v "$table":/fermix-install-releases:ro \
      -v "$work/container-curl":/usr/local/bin/curl:ro \
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

real_curl="$(command -v curl)" || fail "curl is required to run the installer"
mkdir "$work/bin"
write_curl_stand_in "$work/bin/curl" "$table" "$real_curl"

transcript="$(PATH="$work/bin:$PATH" sh "$installer" --no-setup 2>&1)" || {
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
again="$(PATH="$work/bin:$PATH" sh "$installer" --no-setup 2>&1)" || {
  printf '%s\n' "$again"
  fail "the installer refused a machine that already has $version"
}
printf '%s\n' "$again"
case "$again" in
  *"fermix $version is already installed"*) ;;
  *) fail "a second run did not recognise the installed $version" ;;
esac
