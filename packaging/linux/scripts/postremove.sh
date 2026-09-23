#!/bin/sh
# Removing fermix deletes nothing under /var/lib/fermix, on removal and on
# purge alike (M38 §1.3, §2.2).
#
# The trusted loader store is installer-managed state that deliberately
# outlives the package: an engine release that is still running — this
# account's, or another account's — launched against
# /var/lib/fermix/runtimes/<digest>/libc-musl.so and asks the kernel for that
# exact file every time it spawns a helper. Deleting it during an upgrade or a
# removal kills a live VM's next child, and the store is a few hundred
# kilobytes per loader version. Its size is documented in the release notes
# rather than reclaimed here.
#
# This script also operates no user's service manager: a user unit is enabled
# per account, by that account, through `fermix service`.
set -eu

exit 0
