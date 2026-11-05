#!/bin/sh
# Proves packaging/cloud/first-boot.sh: shellcheck on every script here, then
# on_host.sh, which runs the script's own main on this host with the steps
# that need a Debian server as root stood in for (its arguments, the
# enrollment code and the Tailscale step for real against stand-ins), then
# in_container.sh in throwaway debian:trixie-slim containers, one scenario
# each: an existing host typing the code at a terminal and then enrolling with
# a bucket, a restore host, the failures that stop the
# first boot, an Ubuntu host with swap of its own, the nightly update's cases,
# a host joining a tailnet with Tailscale's live signing key, and the
# distribution's Chromium installed for real and started headless as the
# engine account.
# The host part needs shellcheck, dash, script(1) and perl, on macOS or
# Linux; the containers need Docker on Linux 6.2 or later with Landlock
# enabled (the chromium scenario asks the kernel for its Landlock ABI for
# real), the debian:trixie-slim image, and network inside the containers
# (apt-get installs nftables and shellcheck, Chromium in its scenario, and
# ca-certificates, curl and gpg in the tailnet scenario, which reads
# pkgs.tailscale.com).
# Not wired into CI; run it by hand, whole or the host part alone:
#
#   sh packaging/cloud/test/first_boot_test.sh
#   sh packaging/cloud/test/first_boot_test.sh host
set -eu

here=$(cd "$(dirname "$0")" && pwd)
cloud=$(dirname "$here")
systemd_units=$(cd "$cloud/../linux/systemd" && pwd)
image=debian:trixie-slim
mode=${1:-all}

fail() {
  printf 'first_boot_test: %s\n' "$1" >&2
  exit 1
}

case "$mode" in
  all | host) ;;
  *) fail "the only argument is host, which runs the host part alone." ;;
esac
command -v shellcheck >/dev/null 2>&1 || fail "shellcheck is not installed, so the scripts cannot be checked."
if [ "$mode" = all ]; then
  command -v docker >/dev/null 2>&1 || fail "docker is not installed, so first-boot.sh cannot be run in a container; sh $0 host runs the host part alone."
  docker image inspect "$image" >/dev/null 2>&1 || fail "the image $image is not present: docker pull $image"
fi

shellcheck -s sh "$cloud/first-boot.sh" "$here"/*.sh "$here"/stubs/*
echo "ok: shellcheck finds nothing in first-boot.sh and the test scripts"

sh "$here/on_host.sh" || fail "a host check failed; its FAIL lines above say which."
[ "$mode" = all ] || exit 0

status=0
for scenario in existing-host restore failures ubuntu updates tailnet chromium; do
  echo "--- $scenario"
  # Chromium's own sandbox needs the user namespaces a server's kernel gives
  # an unprivileged account; Docker's default seccomp profile refuses them, so
  # that one scenario runs without it, as the process would on the server.
  seccomp=""
  if [ "$scenario" = chromium ]; then seccomp="--security-opt seccomp=unconfined"; fi
  # shellcheck disable=SC2086
  docker run --rm --cap-add NET_ADMIN $seccomp --tmpfs /run:rw,mode=0755 \
    -v "$cloud:/cloud:ro" -v "$systemd_units:/linux-systemd:ro" "$image" \
    sh /cloud/test/in_container.sh "$scenario" || status=1
done
[ "$status" -eq 0 ] || fail "a scenario failed; its FAIL lines above say which checks."
echo "first-boot.sh: every scenario passed"
