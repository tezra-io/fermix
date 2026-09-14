#!/usr/bin/env bash
# Install one built fermix package and prove the engine inside it runs.
#
# The deb rows install on the runner itself, where a systemd user manager and
# `loginctl enable-linger` are available, so the whole service transaction is
# exercised: bind a home whose path contains a space and a percent character,
# enable the unit, prove the daemon answers from that home, then disable it.
#
# The rpm rows install inside a Fedora container, where there is no user
# service manager at all. That is not a degraded deb row: it is the state a
# container has, and the engine must answer it with the structured
# `user_manager_unreachable` error rather than reporting an inactive service.

set -euo pipefail

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

usage() {
  printf 'usage: %s <package> <deb|rpm> <version>\n' "$0" >&2
  exit 2
}

[ "$#" -eq 3 ] || usage

package="$1"
kind="$2"
version="$3"

[ -f "$package" ] || fail "package not found: $package"
[ -n "$version" ] || fail "expected version must not be empty"
package="$(cd "$(dirname "$package")" && pwd)/$(basename "$package")"

# The package file name is the version rule's own evidence: a Debian revision
# would show up here as a `-<n>` before the architecture.
case "$kind" in
  deb)
    expected_prefix="fermix_${version}_"
    case "$(basename "$package")" in
      "${expected_prefix}"*) ;;
      *) fail "deb name $(basename "$package") does not start with $expected_prefix" ;;
    esac
    ;;
  rpm)
    expected_prefix="fermix-${version}-1."
    case "$(basename "$package")" in
      "${expected_prefix}"*) ;;
      *) fail "rpm name $(basename "$package") does not start with $expected_prefix" ;;
    esac
    ;;
  *) fail "unsupported package kind: $kind" ;;
esac

# One reader for the shared envelope: a string prints as itself and everything
# else as its JSON spelling, so `true` is `true` and a missing key is empty.
json_field() {
  python3 -c '
import json, sys
cursor = json.loads(sys.argv[1])
for key in sys.argv[2].split("."):
    if not isinstance(cursor, dict) or key not in cursor:
        print("")
        raise SystemExit(0)
    cursor = cursor[key]
print(cursor if isinstance(cursor, str) else json.dumps(cursor))
' "$1" "$2"
}

if [ "$kind" = rpm ]; then
  command -v docker >/dev/null 2>&1 || fail "docker is required to verify an rpm"

  # A plain container has no user service manager, so `service status` must be
  # the structured refusal. Its own words are the assertion.
  status_output="$(
    docker run --rm -v "$package":/pkg.rpm:ro fedora:41 sh -c '
      set -eu
      dnf install -y /pkg.rpm >/dev/null 2>&1
      fermix --version
      # The rpm family gets its own refusal, on a host whose package database
      # really does own /usr/bin/fermix.
      fermix upgrade 2>&1 | grep -F "dnf upgrade fermix" >/dev/null ||
        { echo "the packaged upgrade refusal did not name dnf" >&2; exit 1; }
      fermix service status --json || true
    '
  )" || fail "the rpm did not install and run inside fedora:41"

  printf '%s\n' "$status_output"

  case "$status_output" in
    *"$version"*) ;;
    *) fail "fermix --version inside the container did not contain $version" ;;
  esac

  envelope="$(printf '%s\n' "$status_output" | tail -n 1)"
  [ "$(json_field "$envelope" ok)" = "false" ] ||
    fail "service status in a container should refuse, and answered: $envelope"
  [ "$(json_field "$envelope" error.code)" = "user_manager_unreachable" ] ||
    fail "service status in a container must answer user_manager_unreachable: $envelope"

  exit 0
fi

: "${RUNNER_TEMP:?RUNNER_TEMP must name a writable directory}"

sudo apt-get install -y "$package"

version_output="$(fermix --version)"
printf '%s\n' "$version_output"
case "$version_output" in
  *"$version"*) ;;
  *) fail "fermix --version does not contain $version" ;;
esac

# The engine reads this file and reports it beside its own compiled identity;
# a mismatch is what `service status` calls an integrity failure.
[ -f /usr/share/fermix/engine.json ] || fail "the package installed no engine manifest"
python3 -c '
import json, sys
manifest = json.load(open("/usr/share/fermix/engine.json"))
assert manifest["distribution_identity"] == "linux_package", manifest
assert manifest["product_version"] == sys.argv[1], manifest
' "$version"

# The trusted loader the package configuration step materialised. Without it
# nothing above would have run at all, so this only names the file.
ls -l /var/lib/fermix/runtimes/*/libc-musl.so

report() {
  printf '%s\n' "$1"
  journalctl --user -u fermix -n 50 --no-pager || true
  fail "$2"
}

status_before="$(fermix service status --json)"
printf '%s\n' "$status_before"
[ "$(json_field "$status_before" ok)" = "true" ] ||
  fail "service status refused before install: $status_before"
[ "$(json_field "$status_before" result.alignment)" = "not_running" ] ||
  fail "a service nobody enabled must report not_running: $status_before"

# A home whose path carries a space and a percent character: both are exactly
# what a systemd unit reads wrong when an assignment is not serialized, and
# both round-trip through the binding because it is JSON data.
home="$RUNNER_TEMP/fermix home 100%/state"
mkdir -p "$home"

sudo loginctl enable-linger "$USER"

install_output="$(fermix service install --json --home "$home")" ||
  report "$install_output" "service install refused"
printf '%s\n' "$install_output"
[ "$(json_field "$install_output" ok)" = "true" ] ||
  report "$install_output" "service install did not report success"

status_after="$(fermix service status --json)"
printf '%s\n' "$status_after"
[ "$(json_field "$status_after" result.active)" = "true" ] ||
  report "$status_after" "the unit is not active after install"
[ "$(json_field "$status_after" result.alignment)" = "aligned" ] ||
  report "$status_after" "the running engine is not the installed one"
[ "$(json_field "$status_after" result.unit.vendor)" = "true" ] ||
  report "$status_after" "the effective unit is not the package's own"
[ "$(json_field "$status_after" result.binding.home)" = "$home" ] ||
  report "$status_after" "the bound home is not the one that was asked for"

uninstall_output="$(fermix service uninstall --json)" ||
  report "$uninstall_output" "service uninstall refused"
printf '%s\n' "$uninstall_output"
[ "$(json_field "$uninstall_output" ok)" = "true" ] ||
  report "$uninstall_output" "service uninstall did not report success"

# The packaged engine refuses to self-update before it looks at a path, and
# names the command for this family instead.
upgrade_output="$(fermix upgrade 2>&1)" && fail "fermix upgrade did not refuse a packaged install"
printf '%s\n' "$upgrade_output"
case "$upgrade_output" in
  *"apt upgrade fermix"*) ;;
  *) fail "the packaged upgrade refusal did not name the package manager: $upgrade_output" ;;
esac
