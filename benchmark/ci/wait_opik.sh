#!/usr/bin/env bash
# Bounded poll of the Opik route the eval harness itself preflights
# (GET /api/v1/private/projects must return JSON — HARNESS.md precondition #1).
# `docker compose up --wait` proves containers healthy; this proves the exact
# API route the harness uses is actually serving.
set -euo pipefail

PROBE_URL="${OPIK_PROBE_URL:-http://localhost:5173/api/v1/private/projects}"
TIMEOUT_S="${OPIK_READY_TIMEOUT:-180}"

# Wall-clock bound (each probe can spend up to its own 5s on top of the sleep,
# so an iteration count would overshoot the advertised timeout).
SECONDS=0
while ((SECONDS < TIMEOUT_S)); do
  if curl -fsS -m 5 "$PROBE_URL" >/dev/null 2>&1; then
    echo "opik ready: $PROBE_URL"
    exit 0
  fi
  sleep 1
done

echo "opik did not become ready within ${TIMEOUT_S}s: $PROBE_URL" >&2
exit 1
