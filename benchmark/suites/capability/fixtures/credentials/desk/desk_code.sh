#!/bin/sh
# Trading-desk connection check: an eval fixture standing in for a skill script
# written for a terminal. It reads the desk token from its environment and
# prints a short code derived from it, never the token itself. The code is a
# polynomial hash of the token's bytes, which cap_skill_credentials' checker
# recomputes from the seeded fixture value.
if [ -z "${FERMIX_EVAL_SKILL_TOKEN:-}" ]; then
  echo "desk_code: FERMIX_EVAL_SKILL_TOKEN is not set" >&2
  exit 2
fi

code=$(printf '%s' "$FERMIX_EVAL_SKILL_TOKEN" | od -A n -t u1 |
  awk '{ for (i = 1; i <= NF; i++) h = (h * 31 + $i) % 1000003 } END { printf "%06d", h }')

echo "desk connection code: DESK-$code"
