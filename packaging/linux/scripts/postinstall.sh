#!/bin/sh
# Materialise the trusted musl loader this engine's ELF interpreters name
# (M38 §1.3). Runs as root, from dpkg and from rpm alike.
#
# The package carries the loader as /usr/lib/fermix/runtime-payload/
# libc-musl-<digest>.so, and every executable inside the engine asks the kernel
# for /var/lib/fermix/runtimes/<digest>/libc-musl.so. This step is what makes
# the second path exist, root-owned, with the bytes the first one carries.
#
# It operates no user's service manager, executes nothing Fermix ships, and
# prints nothing when it succeeds.
set -eu

payload_dir=/usr/lib/fermix/runtime-payload
store=/var/lib/fermix/runtimes
installed=0

fail() {
  echo "fermix: $1" >&2
  exit 1
}

digest_of() {
  sha256sum "$1" | cut -d' ' -f1
}

[ -d "$payload_dir" ] || fail "the runtime payload directory $payload_dir is missing"

for payload in "$payload_dir"/libc-musl-*.so; do
  [ -f "$payload" ] || continue

  name=${payload##*/}
  digest=${name#libc-musl-}
  digest=${digest%.so}

  case "$digest" in
    *[!0-9a-f]* | "") fail "the runtime payload $payload does not name a digest" ;;
  esac

  actual=$(digest_of "$payload")
  [ "$actual" = "$digest" ] ||
    fail "the runtime payload $payload has digest $actual and is named $digest"

  directory="$store/$digest"
  target="$directory/libc-musl.so"

  [ ! -L "$store" ] || fail "$store is a symbolic link, which this package will not follow"
  [ ! -L "$directory" ] ||
    fail "$directory is a symbolic link, which this package will not follow"
  [ ! -L "$target" ] || fail "$target is a symbolic link, which this package will not follow"

  mkdir -p "$directory"
  chown 0:0 "$store" "$directory"
  chmod 0755 "$store" "$directory"

  if [ -f "$target" ] && [ "$(digest_of "$target")" = "$digest" ]; then
    # Already materialised by an earlier version of this package, or by another
    # Fermix that shares the loader. Its bytes are the bytes we would write, and
    # a live release may be running against this exact file.
    installed=$((installed + 1))
    continue
  fi

  [ ! -e "$target" ] || fail "$target exists with different contents and was left alone"

  publish="$directory/.libc-musl.so.incoming"
  rm -f "$publish"
  cp "$payload" "$publish"
  chown 0:0 "$publish"
  chmod 0755 "$publish"
  mv -f "$publish" "$target"
  installed=$((installed + 1))
done

[ "$installed" -gt 0 ] || fail "this package carries no runtime payload, so the engine cannot start"

exit 0
