#!/bin/sh
# Door controller: writes the requested state to workspace/garage.state, which the
# door bridge watches and applies within a second or two.
set -eu
case "${1:-}" in
  open) word=open ;;
  close) word=closed ;;
  *) echo "usage: garage.sh open|close" >&2; exit 2 ;;
esac
here="$(cd "$(dirname "$0")" && pwd)"
home="$(cd "$here/../../.." && pwd)"
printf 'state=%s\n' "$word" > "$home/workspace/garage.state"
echo "garage door: $word"
