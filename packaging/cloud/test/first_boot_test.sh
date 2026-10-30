#!/bin/sh
# Proves packaging/cloud/first-boot.sh: shellcheck on every script here, then
# in_container.sh in throwaway debian:trixie-slim containers, one scenario
# each: an existing host typing the code at a terminal and then enrolling with
# a bucket, a restore host, the failures that stop the
# first boot, an Ubuntu host, and the distribution's Chromium installed for
# real and started headless as the engine account.
# Needs shellcheck, Docker, the debian:trixie-slim image, and network inside
# the containers (apt-get installs nftables, and Chromium in its scenario).
# Not wired into CI; run it by hand:
#
#   sh packaging/cloud/test/first_boot_test.sh
set -eu

here=$(cd "$(dirname "$0")" && pwd)
cloud=$(dirname "$here")
systemd_units=$(cd "$cloud/../linux/systemd" && pwd)
image=debian:trixie-slim

fail() {
  printf 'first_boot_test: %s\n' "$1" >&2
  exit 1
}

command -v shellcheck >/dev/null 2>&1 || fail "shellcheck is not installed, so the scripts cannot be checked."
command -v docker >/dev/null 2>&1 || fail "docker is not installed, so first-boot.sh cannot be run."
docker image inspect "$image" >/dev/null 2>&1 || fail "the image $image is not present: docker pull $image"

shellcheck -s sh "$cloud/first-boot.sh" "$here"/*.sh "$here"/stubs/*
echo "ok: shellcheck finds nothing in first-boot.sh and the test scripts"

status=0
for scenario in existing-host restore failures ubuntu chromium; do
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
