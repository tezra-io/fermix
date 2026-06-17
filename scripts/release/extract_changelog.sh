#!/usr/bin/env bash
#
# Extract a single version's section body from a Keep a Changelog CHANGELOG.md.
#
# Usage: extract_changelog.sh <version> [changelog_path]
#
# Prints everything under the "## [<version>] ..." header up to (but not
# including) the next "## [" header. The header line itself and surrounding
# blank lines are stripped. The release pipeline feeds this into the GitHub
# Release body, so a missing or empty section must FAIL LOUD (non-zero exit)
# rather than publish a release with no notes.
set -euo pipefail

version="${1:?usage: extract_changelog.sh <version> [changelog_path]}"
changelog="${2:-CHANGELOG.md}"

if [ ! -f "$changelog" ]; then
  echo "extract_changelog: changelog not found: $changelog" >&2
  exit 1
fi

awk -v ver="$version" '
  function emit(    s, e, i) {
    s = 1;  while (s <= n && lines[s] ~ /^[[:space:]]*$/) s++
    e = n;  while (e >= s && lines[e] ~ /^[[:space:]]*$/) e--
    for (i = s; i <= e; i++) print lines[i]
    return e - s + 1
  }
  /^## \[/ {
    tag = $0; sub(/^## \[/, "", tag); sub(/\].*/, "", tag)
    if (cap) cap = 0                        # next version header ends the section
    if (tag == ver) { cap = 1; n = 0; seen = 1; next }
  }
  cap { lines[++n] = $0 }
  END {
    if (!seen) {
      print "extract_changelog: no entry for version [" ver "] in changelog" > "/dev/stderr"
      exit 2
    }
    if (emit() == 0) {
      print "extract_changelog: section [" ver "] is empty" > "/dev/stderr"
      exit 3
    }
  }
' "$changelog"
