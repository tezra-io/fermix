#!/bin/sh
# Fixture door controller for the eval home: records the requested state in the home's
# workspace (garage.state), which the capability checker reads. Nothing real moves.
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
