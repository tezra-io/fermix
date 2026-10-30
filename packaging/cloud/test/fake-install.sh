#!/bin/sh
# What the curl stand-in serves for https://fermix.ai/install: puts the
# stand-in fermix where the package puts the real one, and the package's own
# systemd user unit where the package puts it.
set -eu
printf 'installer %s\n' "$*" >>/var/log/fermix-test/calls.log
install -m 0755 /cloud/test/stubs/fermix /usr/bin/fermix
install -D -m 0644 /linux-systemd/fermix.service /usr/lib/systemd/user/fermix.service
echo "==> (test) installed the stand-in fermix"
