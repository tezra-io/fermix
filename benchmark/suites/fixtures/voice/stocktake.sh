#!/bin/sh
# Fennwick Community Pantry stocktake report for one day.
# Usage: sh stocktake.sh YYYY-MM-DD
# Counting the shelves takes about half a minute.
set -eu
day="${1:?usage: sh stocktake.sh YYYY-MM-DD}"
sleep 25
rows=$(grep "^$day	" "$(dirname "$0")/stocktake.tsv" || true)
if [ -z "$rows" ]; then
  echo "no stocktake recorded for $day" >&2
  exit 1
fi
printf 'Stocktake for %s\n' "$day"
printf '%s\n' "$rows" | cut -f2-
