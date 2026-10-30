#!/bin/sh
# What the curl stand-in serves for https://fermix.ai/install: puts the
# stand-in fermix where the package puts the real one, and the package's own
# systemd user unit where the package puts it, and records the release it
# installed (/etc/fermix-test/release, else 1.2.3) where the dpkg-query
# stand-in reads it. It stops, as a failed download or install does, while
# /etc/fermix-test/installer-fails exists.
set -eu
printf 'installer %s\n' "$*" >>/var/log/fermix-test/calls.log
if [ -f /etc/fermix-test/installer-fails ]; then
  echo "install.sh: (test) the download failed" >&2
  exit 1
fi
release=1.2.3
if [ -f /etc/fermix-test/release ]; then release=$(cat /etc/fermix-test/release); fi
install -m 0755 /cloud/test/stubs/fermix /usr/bin/fermix
install -D -m 0644 /linux-systemd/fermix.service /usr/lib/systemd/user/fermix.service
install -d /var/lib/fermix-test
printf '%s\n' "$release" >/var/lib/fermix-test/installed-version
echo "==> (test) installed the stand-in fermix"
