#!/bin/sh
# Writes packaging/cloud/first-boot.sh into the CloudFormation template's user
# data, compressed (user data holds at most 16 KB), with the SHA-256 the server
# checks before running it. Run it after every change to first-boot.sh;
# packaging/cloud/test/first_boot_test.sh fails while the two differ.
#
#   sh packaging/cloud/aws/embed-first-boot.sh
set -eu

here=$(cd "$(dirname "$0")" && pwd)
script=$here/../first-boot.sh
template=$here/fermix-always-on.yaml
begin='# >>> first-boot.sh'
end='# <<< first-boot.sh'

fail() {
  printf 'embed-first-boot: %s\n' "$1" >&2
  exit 1
}

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

[ -f "$script" ] || fail "$script is missing."
[ "$(grep -c "^ *$begin" "$template")" -eq 1 ] || fail "$template must hold exactly one line starting $begin."
[ "$(grep -c "^ *$end" "$template")" -eq 1 ] || fail "$template must hold exactly one line starting $end."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

gzip -9 -n -c "$script" | base64 | tr -d '\n' | fold -w 76 >"$work/blob"
printf '\n' >>"$work/blob"
digest=$(sha256 "$script")

awk -v begin="$begin" -v end="$end" -v blob="$work/blob" -v digest="$digest" '
  { match($0, /^ */); pad = substr($0, 1, RLENGTH); text = substr($0, RLENGTH + 1) }
  substr(text, 1, length(begin)) == begin {
    print
    print pad "- |"
    while ((getline part < blob) > 0) print pad "  " part
    print pad "  FERMIX_FIRST_BOOT"
    print pad "  printf '\''%s  %s\\n'\'' " digest " /usr/local/lib/fermix-always-on/first-boot.sh | sha256sum -c --quiet"
    skipping = 1
    next
  }
  substr(text, 1, length(end)) == end { skipping = 0 }
  !skipping { print }
' "$template" >"$work/template"

cat "$work/template" >"$template"
printf 'Embedded first-boot.sh (sha256 %s) in %s\n' "$digest" "$template"
