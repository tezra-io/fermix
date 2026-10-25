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
  printf 'usage: %s <package> <deb|rpm> <version> [<iroh-helper-pin>]\n' "$0" >&2
  exit 2
}

[ "$#" -eq 3 ] || [ "$#" -eq 4 ] || usage

package="$1"
kind="$2"
version="$3"
# The helper the package must carry is the one this checkout pins.
iroh_pin="${4:-$(cd "$(dirname "$0")/../.." && pwd -P)/apps/fermix_core/priv/iroh_helper/PIN.json}"

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

# The architecture in the package's name names the helper build it must carry.
package_arch="$(basename "$package")"
package_arch="${package_arch#"$expected_prefix"}"
package_arch="${package_arch%".$kind"}"
case "$kind:$package_arch" in
  deb:amd64|rpm:x86_64) target=linux_x86_64 ;;
  deb:arm64|rpm:aarch64) target=linux_aarch64 ;;
  *) fail "cannot tell the target of $(basename "$package"): architecture '$package_arch' is not a $kind architecture fermix ships" ;;
esac

# One reader for the shared envelope: a string prints as itself and everything
# else as its JSON spelling, so `true` is `true` and a missing key is empty.
json_field() {
  uv run --no-project python -c '
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

# The pinned fermix-iroh build for this target: its digest, the exact
# `--version` line it prints and the digest of its notices. Read before
# anything is installed.
[ -f "$iroh_pin" ] || fail "iroh helper pin not found: $iroh_pin"
iroh_pin_json="$(cat "$iroh_pin")"
[ "$(json_field "$iroh_pin_json" schema_version)" = 2 ] ||
  fail "the iroh helper pin $iroh_pin is not schema_version 2"
iroh_sha256="$(json_field "$iroh_pin_json" "targets.$target.sha256")"
printf '%s\n' "$iroh_sha256" | grep -Eqx '[0-9a-f]{64}' ||
  fail "the iroh helper pin $iroh_pin has no sha256 for $target"
iroh_notices_sha256="$(json_field "$iroh_pin_json" notices.sha256)"
printf '%s\n' "$iroh_notices_sha256" | grep -Eqx '[0-9a-f]{64}' ||
  fail "the iroh helper pin $iroh_pin has no sha256 for the notices"
iroh_helper_version="$(json_field "$iroh_pin_json" version)"
iroh_iroh_version="$(json_field "$iroh_pin_json" iroh_version)"
[ -n "$iroh_helper_version" ] && [ -n "$iroh_iroh_version" ] ||
  fail "the iroh helper pin $iroh_pin must name version and iroh_version"
iroh_version_line="fermix-iroh $iroh_helper_version (iroh $iroh_iroh_version)"

# The helper check both families run on the installed package: on the runner
# for a deb, and inside the container for an rpm, where only coreutils can be
# relied on, so it is POSIX sh with sha256sum. The Burrito wrapper names the
# directory it unpacked its payload into, so the helper is looked for exactly
# where the `fermix --version` before it put it. The digest is checked before
# the helper runs, so no unpinned bytes are executed. The helper's third-party
# notices are checked twice, beside it in the payload and as the package's own
# document, and the copyright file must name the helper, its licence, that
# document and the one crate in it under the MPL 2.0.
# shellcheck disable=SC2016
iroh_helper_check='
set -eu
fail() { printf "error: %s\n" "$1" >&2; exit 1; }
expected_sha256="$1"
expected_version="$2"
expected_notices_sha256="$3"
doc_notices=/usr/share/doc/fermix/fermix-iroh-THIRD-PARTY-NOTICES.txt
copyright=/usr/share/doc/fermix/copyright
check_notices() {
  [ -f "$1" ] && [ ! -L "$1" ] || fail "the fermix-iroh third-party notices are not a regular file at $1"
  mode="$(stat -c %a "$1")" || fail "cannot read the mode of the fermix-iroh notices at $1"
  [ "$mode" = 644 ] || fail "the fermix-iroh notices at $1 must be mode 0644, found $mode"
  actual="$(sha256sum "$1" | cut -d " " -f 1)"
  [ "$actual" = "$expected_notices_sha256" ] ||
    fail "the fermix-iroh notices at $1 are not the pinned ones: expected sha256 $expected_notices_sha256, found $actual"
}
payload="$(fermix maintenance directory)" ||
  fail "fermix maintenance directory did not name the unpacked payload"
[ -d "$payload" ] || fail "the unpacked payload directory does not exist: $payload"
count=0
helper=""
for candidate in "$payload"/lib/fermix_core-*/priv/iroh_helper/bin/fermix-iroh; do
  [ -e "$candidate" ] || continue
  count=$((count + 1))
  helper="$candidate"
done
[ "$count" -eq 1 ] ||
  fail "the unpacked payload must carry exactly one fermix-iroh helper (lib/fermix_core-*/priv/iroh_helper/bin/fermix-iroh under $payload), found $count"
[ -f "$helper" ] && [ -x "$helper" ] ||
  fail "the bundled fermix-iroh helper is not an executable file: $helper"
actual_sha256="$(sha256sum "$helper" | cut -d " " -f 1)"
[ "$actual_sha256" = "$expected_sha256" ] ||
  fail "the bundled fermix-iroh helper is not the pinned build: expected sha256 $expected_sha256, found $actual_sha256"
actual_version="$("$helper" --version < /dev/null)" ||
  fail "the bundled fermix-iroh helper --version failed: $helper"
[ "$actual_version" = "$expected_version" ] ||
  fail "the bundled fermix-iroh helper --version must print exactly \"$expected_version\", got \"$actual_version\""
printf "fermix-iroh helper: %s (%s)\n" "$helper" "$actual_version"
check_notices "${helper%/bin/fermix-iroh}/THIRD-PARTY-NOTICES.txt"
check_notices "$doc_notices"
for line in "/usr/bin/fermix also contains the fermix-iroh helper" \
  "Copyright (c) 2026 Tezra.io, MIT License." "$doc_notices" \
  "One crate in the helper, attohttpc, is under the Mozilla Public License 2.0."; do
  grep -Fq -- "$line" "$copyright" || fail "$copyright does not name the fermix-iroh helper and its notices: no line has \"$line\""
done
printf "fermix-iroh notices: %s\n" "$doc_notices"
'

if [ "$kind" = rpm ]; then
  command -v docker >/dev/null 2>&1 || fail "docker is required to verify an rpm"

  # A plain container has no user service manager, so `service status` must be
  # the structured refusal. Its own words are the assertion. The helper check
  # and what it expects go in by environment; its report goes to stderr so the
  # last stdout line stays the status envelope.
  status_output="$(
    docker run --rm -v "$package":/pkg.rpm:ro \
      -e IROH_HELPER_CHECK="$iroh_helper_check" \
      -e IROH_SHA256="$iroh_sha256" \
      -e IROH_VERSION_LINE="$iroh_version_line" \
      -e IROH_NOTICES_SHA256="$iroh_notices_sha256" \
      fedora:41 sh -c '
      set -eu
      dnf install -y /pkg.rpm >/dev/null 2>&1
      fermix --version
      sh -c "$IROH_HELPER_CHECK" iroh-helper-check "$IROH_SHA256" "$IROH_VERSION_LINE" "$IROH_NOTICES_SHA256" >&2
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

# The run above unpacked the payload; the pinned helper must be in it, with its
# notices beside it and installed as the package's own document.
sh -c "$iroh_helper_check" iroh-helper-check "$iroh_sha256" "$iroh_version_line" "$iroh_notices_sha256" ||
  fail "the deb does not carry the pinned fermix-iroh helper and its notices for $target (the reason is above)"

# The engine reads this file and reports it beside its own compiled identity;
# a mismatch is what `service status` calls an integrity failure.
[ -f /usr/share/fermix/engine.json ] || fail "the package installed no engine manifest"
uv run --no-project python -c '
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

# A management client reaches the packaged daemon: a read-only `settings show`
# over the socket of the bound home, at a path with a space and a percent
# character. The client dials $FERMIX_HOME, not the service binding, so the home
# is named the way an owner with a non-default home names it.
settings_output="$(FERMIX_HOME="$home" fermix settings show secrets --json)" ||
  report "$settings_output" "fermix settings show refused against the packaged daemon"
printf '%s\n' "$settings_output"
[ "$(json_field "$settings_output" id)" = "secrets" ] ||
  report "$settings_output" "fermix settings show secrets did not answer with the secrets section"

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
