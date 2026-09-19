#!/usr/bin/env bash
# The attached-tab slice end to end, against a real Chromium. NEVER part of
# `mix test`: it launches a browser.
#
# Everything it touches is thrown away — its own FERMIX_HOME, its own Chrome
# user-data-dir, its own native-messaging host manifest INSIDE that directory.
# It never reads or writes the operator's Chrome profile, and it never installs
# a browser. It needs one that still honours `--load-extension`; branded Chrome
# no longer does, so it looks for Chrome for Testing (Playwright installs one).
#
# Usage: scripts/dev/attached_tab_e2e.sh [path-to-chrome]

set -euo pipefail

cd "$(dirname "$0")/../.."
repo="$PWD"
extension="$repo/apps/fermix_core/priv/browser_extension"

find_chrome() {
  if [ "$#" -ge 1 ] && [ -n "${1:-}" ]; then
    printf '%s\n' "$1"
    return 0
  fi
  # Newest build first: an older Chrome for Testing can start and never write
  # `DevToolsActivePort`, which reads as a hang rather than as the wrong binary.
  local candidates=()
  while IFS= read -r line; do candidates+=("$line"); done < <(
    ls -d "$HOME/Library/Caches/ms-playwright"/chromium-*/ 2>/dev/null | sort -t- -k2 -rn
  )
  for dir in "${candidates[@]}"; do
    for leaf in chrome-mac-arm64 chrome-mac; do
      candidate="$dir$leaf/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"
      [ -x "$candidate" ] && printf '%s\n' "$candidate" && return 0
    done
  done
  for candidate in \
    "/Applications/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing" \
    "$(command -v chromium || true)" \
    "$(command -v chromium-browser || true)"; do
    [ -n "$candidate" ] && [ -x "$candidate" ] && printf '%s\n' "$candidate" && return 0
  done
  return 1
}

if ! chrome="$(find_chrome "${1:-}")"; then
  printf 'attached-tab e2e: no Chromium that accepts --load-extension is installed.\n' >&2
  printf 'Install Chrome for Testing (or pass its path) and run this again. Nothing was started.\n' >&2
  exit 3
fi
printf 'attached-tab e2e: using %s\n' "$chrome"

root="$(mktemp -d "${TMPDIR:-/tmp}/fermix-attached-e2e.XXXXXX")"
# Short enough for a Unix socket address (~104 bytes) once the socket name is on
# the end; mktemp under TMPDIR on macOS is already close to the limit.
short_root="$(mktemp -d "/tmp/fx-e2e.XXXXXX")"
status=0

cleanup() {
  if [ -f "$short_root/chrome.pid" ]; then
    chrome_pid="$(cat "$short_root/chrome.pid")"
    kill "$chrome_pid" 2>/dev/null || true
    sleep 1
    kill -9 "$chrome_pid" 2>/dev/null || true
  fi
  # Anything the script spawned that outlived it: the browser's own children and
  # any pump the extension started. Matched on this run's directories only, so a
  # developer's own Chrome and daemon are never in scope.
  pkill -f "$short_root" 2>/dev/null || true
  sleep 1
  leftovers="$(pgrep -f "$short_root" 2>/dev/null || true)"
  if [ -n "$leftovers" ]; then
    printf 'attached-tab e2e: processes survived cleanup: %s\n' "$leftovers" >&2
    ps -o pid,command -p $leftovers >&2 || true
    status=1
  fi
  rm -rf "$root" "$short_root"
}
trap cleanup EXIT

# Set here as well as in the script: nothing this run does may reach the
# operator's own home, not even before the script's first line.
export FERMIX_HOME="$short_root/fermix-home"
mkdir -p "$FERMIX_HOME"

MIX_ENV="${MIX_ENV:-dev}" mix run --no-start scripts/dev/attached_tab_e2e.exs \
  "$short_root" "$chrome" "$extension" || status=$?

exit "$status"
