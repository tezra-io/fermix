#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_FILE="$ROOT_DIR/Sources/FermixPet/CompanionState.swift"

fail() {
  echo "runtime_policy_test: $*" >&2
  exit 1
}

if rg -n "warmCapture\\(" "$STATE_FILE" >/dev/null; then
  fail "connect path must not pre-warm microphone capture"
fi

if ! awk '
  /func endCall\(\)/ { in_end_call = 1 }
  in_end_call && /shutdownAudio\(\)/ { found = 1 }
  in_end_call && /^    func / && !/func endCall\(\)/ { in_end_call = 0 }
  END { exit(found ? 0 : 1) }
' "$STATE_FILE"; then
  fail "endCall must fully shut down audio"
fi

if rg -n "audio\\.stopCapture\\(\\)" "$STATE_FILE" >/dev/null; then
  fail "CompanionState must use full audio.shutdown() for teardown"
fi

echo "runtime_policy_test: ok"
