#!/bin/sh
# The check an Always On server makes before it installs a package as an
# update, made on one of the release's debs: first-boot.sh's own
# release_signature_holds, with the cosign that deb ships at
# usr/lib/fermix/cosign (unpacked here, never the runner's, which signed
# it) and a Sigstore cache of its own, as empty as a server's before its
# first update. A cosign that refuses the release's own signature would make
# every server refuse the release, so the release stops here instead.
#
#   scripts/release/verify_update_signature.sh DEB VERSION
#
# DEB's .sig and .pem are beside it, as the release signs it; VERSION is the
# release's, without the tag's v. The command and its flags are
# first-boot.sh's alone: this script runs that function and holds no copy.
set -eu

fail() {
  printf 'verify_update_signature: %s\n' "$1" >&2
  exit 1
}

[ "$#" -eq 2 ] || {
  printf 'usage: %s DEB VERSION\n' "$0" >&2
  exit 2
}
[ -f "$1" ] || fail "$1 is not there."
for signed in "$1.sig" "$1.pem"; do
  [ -f "$signed" ] || fail "$signed is not there: the release signs each deb beside it."
done
work=$(cd "$(dirname "$1")" && pwd)
name=$(basename "$1")
version=$2
first_boot=$(cd "$(dirname "$0")/../../packaging/cloud" && pwd)/first-boot.sh
# first-boot.sh runs its main on its last line; the copy read here ends
# before it, as its tests read it.
[ "$(tail -n 1 "$first_boot")" = 'main "$@"' ] || fail "$first_boot no longer ends with main \"\$@\"."

scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
mkdir "$scratch/package" "$scratch/sigstore"
dpkg-deb -x "$1" "$scratch/package" || fail "dpkg-deb could not unpack $name."
cosign=$scratch/package/usr/lib/fermix/cosign
[ -x "$cosign" ] || fail "$name ships no executable usr/lib/fermix/cosign, so no Always On server could check an update to it."
sed '$d' "$first_boot" >"$scratch/first-boot.sh"

# A shell of its own, so first-boot.sh's names stay out of this one's.
# shellcheck disable=SC2016 # expanded by that shell, from its arguments
if ! sh -c '
  . "$1"
  COSIGN=$2
  SIGSTORE_DIR=$3
  WORK=$4
  eval "$(release_checks)"
  release_signature_holds "$5" "$6"
' first-boot "$scratch/first-boot.sh" "$cosign" "$scratch/sigstore" "$work" "$version" "$name"; then
  fail "the cosign $name ships refused its release signature (its message above says why), so every Always On server would refuse this release as an update."
fi
printf "ok: the cosign %s ships verifies its release signature as an Always On server's update does\n" "$name"
