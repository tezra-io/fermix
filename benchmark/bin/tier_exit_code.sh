#!/usr/bin/env bash
#
# Which tier exit code the eval-box job publishes.
#
# Every tier step in .github/workflows/eval-box.yml publishes its RUNNER's exit
# code, because those codes carry distinctions `make` collapses (bin/tier.sh's
# header lists them). The job must then publish ONE of them, and the YAML
# expression that used to choose got every capability run wrong: `||` yields the
# first TRUTHY operand and the string "0" is truthy, so the green deterministic
# axis published "0" and the judged axis's 5 — valid, recorded, release gate RED
# — never left the job. The callers classified a real recorded result as a plain
# failure. This script is that choice, in a file a test can run.
#
# The rule, walked in the order the steps ran: the FIRST step that FAILED
# decides, and its code is the answer. First in order, because that is the
# failure the run hit first and every later step ran in its shadow. Ranking the
# codes instead would invent an ordering they deliberately do not have — 4 (no
# valid measurement) and 5 (valid, gate red) are different kinds, not degrees,
# and a new code would have to be slotted into a scale that means nothing. Every
# result received is echoed to stderr, so the code that lost stays in the log.
#
# Each step arrives as its GitHub Actions OUTCOME and the code it published,
# because the two absences are not the same thing. A step that never ran is no
# evidence at all. A step that FAILED WITHOUT PUBLISHING died before its runner
# did (`make check` refused the box, the VM was killed): it decided the run and
# has no code to describe it, so this exits 3 rather than let a later step's
# code speak for it — publishing the judged axis's 5 for a deterministic sweep
# that never happened would file "valid and recorded" about nothing. Nothing ran
# at all exits 3 too. Either way the job output stays empty and the callers read
# a tier that failed without a code, never a pass: answering "0" for an absence
# would be this script's own defect rewritten.
#
#   bin/tier_exit_code.sh <step>=<outcome>:<code> [...]
#
# <outcome> is `steps.<id>.outcome` (success · failure · cancelled · skipped, or
# empty for a step the run never reached) and <code> is `steps.<id>.outputs
# .exit_code`, empty when the step published none. Steps are given in the order
# they ran. This script's own status is not a tier code: 0 a code was chosen and
# printed · 2 the arguments are unusable · 3 no code describes this run.
set -euo pipefail

usage() {
  printf 'usage: %s <step>=<outcome>:<code> [<step>=<outcome>:<code> ...]\n' \
    "$(basename "${BASH_SOURCE[0]}")" >&2
}

die() {
  printf 'tier_exit_code: %s\n' "$1" >&2
  exit 2
}

# A published code is a bare decimal 0-255. Leading zeros are refused because
# the callers compare the string: `05` would classify as a plain failure, the
# very mislabel this script exists to prevent.
check_code() {
  case "$2" in
    0) return 0 ;;
    0*) die "$1 published '$2'; an exit code carries no leading zero" ;;
    *[!0-9]*) die "$1 published '$2', which is not an exit code" ;;
  esac
  [ "$2" -le 255 ] || die "$1 published '$2', which is not an exit code"
}

[ $# -ge 1 ] || { usage; exit 2; }

seen=()
names=""
published=0
decider=""
decided=""

for arg in "$@"; do
  step=${arg%%=*}
  result=${arg#*=}
  outcome=${result%%:*}
  code=${result#*:}
  [ "$step" != "$arg" ] || die "not a <step>=<outcome>:<code> argument: '$arg'"
  [ "$outcome" != "$result" ] || die "$step: no outcome in '$result'"
  [ -n "$step" ] || die "argument with no step name: '$arg'"
  # A step id, nothing else: a mangled name would also slip past the
  # named-twice check below, which matches on a space-separated list.
  case "$step" in
    *[!A-Za-z0-9_-]*) die "not a step id: '$step'" ;;
  esac
  case " $names " in
    *" $step "*) die "step named twice, so one result would be lost: $step" ;;
  esac
  names="$names $step"
  seen+=("$step=$outcome:${code:-<none>}")

  case "$outcome" in
    success|failure) [ -z "$code" ] || check_code "$step" "$code" ;;
    ''|skipped|cancelled) [ -z "$code" ] || die "$step did not run but published '$code'" ;;
    *) die "$step: '$outcome' is not a step outcome" ;;
  esac
  case "$outcome:$code" in
    success:) die "$step succeeded without publishing a code" ;;
    success:0) published=$((published + 1)) ;;
    success:*) die "$step succeeded but published '$code'" ;;
    failure:) ;;
    failure:0) die "$step failed but published 0" ;;
    failure:*) published=$((published + 1)) ;;
  esac
  if [ "$outcome" = failure ] && [ -z "$decider" ]; then
    decider="$step"
    decided="$code"
  fi
done

printf 'tier_exit_code: %s\n' "${seen[*]}" >&2

if [ -n "$decider" ] && [ -z "$decided" ]; then
  printf 'tier_exit_code: %s failed before publishing a code, so no code describes this run\n' \
    "$decider" >&2
  exit 3
fi

if [ -n "$decider" ]; then
  printf 'tier_exit_code: %s decided the run with %s\n' "$decider" "$decided" >&2
  printf '%s\n' "$decided"
  exit 0
fi

if [ "$published" -eq 0 ]; then
  printf 'tier_exit_code: no tier step ran, so there is nothing to publish\n' >&2
  exit 3
fi

printf 'tier_exit_code: every step that ran was green\n' >&2
printf '0\n'
