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
#                                 first print where the judge's ANTHROPIC_API_KEY
#                                 comes from, never its value.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

TIERS="regression|behavioral-isolated|capability|capability-judged|capability-readonly|capability-private"

usage() {
  printf 'usage: %s [--print] <%s>\n' "$(basename "${BASH_SOURCE[0]}")" "$TIERS" >&2
}

# The Claude judge's credential (judge.backend in config.yaml and
# behavioral_config.yaml): ANTHROPIC_API_KEY if exported (the CI eval box feeds it
# from the ANTHROPIC_API_KEY repository secret, the candidate daemon's own key),
# else the daemon's configured Anthropic key from the macOS keychain (the entry
# `@keyring` resolves to), so judged targets need no separate setup. When neither
# answers nothing is exported and the SDK resolves a profile on its own (an `ant
# auth login` profile); the runner's judge precondition refuses the run with a
# sentence when nothing resolves.
JUDGE_KEYCHAIN_ITEM="fermix:ANTHROPIC_API_KEY"
judge_keychain_key() {
  security find-generic-password -s "$JUDGE_KEYCHAIN_ITEM" -a fermix -w 2>/dev/null || true
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
  capability-private)
    # The private holdout (config private_suites.dir): the scored real-use tier. Its
    # editing and drafting tasks are judge-graded, so the judge key is resolved too.
    judged=1
    cmd=(uv run bin/run_capability.py --private --trials 5 --judge)
    for flag in \
      "$(attest "${CONFIRM_DAEMON_ISOLATED:-}" --confirm-daemon-isolated)" \
      "$(attest "${CONFIRM_ISOLATED_ENV:-}" --confirm-isolated-env)" \
      "$(attest "${CONFIRM_COST:-}" --confirm-cost)"; do
      if [ -n "$flag" ]; then cmd+=("$flag"); fi
    done ;;
  *)
    usage; exit 2 ;;
esac

judge_source=""
if [ "$judged" -eq 1 ]; then
  if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    judge_source="<environment>"
  else
    keychain_key="$(judge_keychain_key)"
    if [ -n "$keychain_key" ]; then
      ANTHROPIC_API_KEY="$keychain_key"
      export ANTHROPIC_API_KEY
      judge_source="<keychain $JUDGE_KEYCHAIN_ITEM>"
    else
      judge_source="<unset>"
    fi
    unset keychain_key
  fi
fi

if [ "$print_only" -eq 1 ]; then
  if [ -n "$judge_source" ]; then
    printf 'ANTHROPIC_API_KEY=%s\n' "$judge_source"
  fi
  printf '%s\n' "${cmd[@]}"
  exit 0
fi

case "$judge_source" in
  "") ;;
  "<unset>")
    printf 'tier.sh: no ANTHROPIC_API_KEY in the environment or the keychain item %s; the judge signs in with an `ant auth login` profile, or the runner refuses the judged run\n' \
      "$JUDGE_KEYCHAIN_ITEM" >&2 ;;
  *)
    printf 'tier.sh: the judge signs in with ANTHROPIC_API_KEY from %s\n' "$judge_source" >&2 ;;
esac

exec "${cmd[@]}"
