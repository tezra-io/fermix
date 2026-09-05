#!/usr/bin/env bash
#
# The live eval tiers — one definition of what each one runs.
#
# Why a script and not a Makefile recipe: the runners answer with distinct exit
# codes and every caller classifies on them. run_capability.py: 0 valid+green ·
# 2 refused selection · 3 preconditions/no route · 4 measurement invalid ·
# 5 valid and recorded, release gate RED. run_eval.py: 0 green · 1 gates red ·
# 4 measurement invalid. GNU make reports ANY recipe failure as exit 2, so a
# tier invoked through make can never tell a red release gate from a missing
# measurement — the exact distinction those codes exist to carry. This script
# `exec`s the runner, so the runner's exit code IS the caller's.
#
# `make <tier>` is a thin alias for this script; .github/workflows/eval-box.yml
# and scripts/vultr-box.sh call it directly, because they publish or classify
# the code.
#
#   bin/tier.sh <tier>            run the tier (execs the runner)
#   bin/tier.sh --print <tier>    print the argv it would exec, one per line,
#                                 and exit 0 — the test seam (bin/test_tier.py),
#                                 never a second execution path. Judged tiers
#                                 print their EVAL_JUDGE_API_KEY prefix first,
#                                 redacted to <set>/<unset>.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

TIERS="regression|behavioral-isolated|capability|capability-judged|capability-readonly"

usage() {
  printf 'usage: %s [--print] <%s>\n' "$(basename "${BASH_SOURCE[0]}")" "$TIERS" >&2
}

# The external judge key: EVAL_JUDGE_API_KEY if exported, else the daemon's
# configured OpenAI key from the macOS keychain (the entry `@keyring` resolves
# to), so judged targets need no separate setup. Empty when neither answers —
# the runner refuses the judged run itself, naming the key.
judge_key() {
  if [ -n "${EVAL_JUDGE_API_KEY:-}" ]; then
    printf '%s' "$EVAL_JUDGE_API_KEY"
    return 0
  fi
  security find-generic-password -s fermix:OPENAI_API_KEY -a fermix -w 2>/dev/null || true
}

# An attestation is a human claim about the environment, so only an explicit
# grant word counts; anything else (including empty and unset) withholds it.
attest() {
  case "${1:-}" in
    1|true|yes) printf '%s' "$2" ;;
  esac
}

print_only=0
if [ "${1:-}" = "--print" ]; then
  print_only=1
  shift
fi
[ $# -eq 1 ] || { usage; exit 2; }

judged=0
case "$1" in
  regression)
    judged=1
    cmd=(uv run bin/run_eval.py --tag host-safe-core --judge --fail-retries 2) ;;
  behavioral-isolated)
    judged=1
    cmd=(uv run bin/run_eval.py --profile isolated_mutation --all --judge --fail-retries 2
         --confirm-daemon-isolated --confirm-isolated-env) ;;
  capability)
    cmd=(uv run bin/run_capability.py --trials 5)
    for flag in \
      "$(attest "${CONFIRM_DAEMON_ISOLATED:-}" --confirm-daemon-isolated)" \
      "$(attest "${CONFIRM_ISOLATED_ENV:-}" --confirm-isolated-env)" \
      "$(attest "${CONFIRM_COST:-}" --confirm-cost)"; do
      if [ -n "$flag" ]; then cmd+=("$flag"); fi
    done ;;
  capability-judged)
    # --threshold 0.5 is the bar response_quality.yaml documents for this axis: a
    # fractional taste score binarized at 1.0 makes pass^k meaningless, not strict.
    judged=1
    cmd=(uv run bin/run_capability.py --suite cap_response_quality --trials 5 --judge --threshold 0.5) ;;
  capability-readonly)
    cmd=(uv run bin/run_capability.py --trials 5 --suite cap_web_research --suite cap_web_app) ;;
  *)
    usage; exit 2 ;;
esac

if [ "$judged" -eq 1 ]; then
  EVAL_JUDGE_API_KEY="$(judge_key)"
  export EVAL_JUDGE_API_KEY
fi

if [ "$print_only" -eq 1 ]; then
  if [ "$judged" -eq 1 ] && [ -n "$EVAL_JUDGE_API_KEY" ]; then
    printf 'EVAL_JUDGE_API_KEY=<set>\n'
  elif [ "$judged" -eq 1 ]; then
    printf 'EVAL_JUDGE_API_KEY=<unset>\n'
  fi
  printf '%s\n' "${cmd[@]}"
  exit 0
fi

exec "${cmd[@]}"
