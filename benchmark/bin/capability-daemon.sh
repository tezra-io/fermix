#!/usr/bin/env bash
#
# Disposable capability-eval daemon lifecycle.
#
# Automates the manual setup in benchmark/README.md §3: seeds a throwaway
# FERMIX_HOME, starts a daemon that scores the ~/.fermix-dev primary model in a
# strict sandbox, waits for readiness, and tears it down. It never touches the
# operator's live ~/.fermix or ~/.fermix-dev daemon (different home => different
# control socket; --no-web => no shared port).
#
#   capability-daemon.sh up        seed (config; with --cues the cue watchers too) + snapshot
#                                  the seeded state + start the keeper, which starts the
#                                  daemon + wait ready; a fresh up starts a new daemon.log.
#                                  Up is a keeper that answers and a daemon that does: with
#                                  both, up says "already up" (exit 0); with anything else
#                                  of an earlier up running (a keeper whose daemon exited,
#                                  a daemon without its keeper, one started by hand) it
#                                  refuses (exit 3) with what clears it
#   capability-daemon.sh down      stop the keeper (it stops its daemon) + clean the sockets
#   capability-daemon.sh reset     ask the keeper to stop its daemon, restore the snapshot
#                                  `up` took and start the daemon again with `up`'s
#                                  environment, so the next attempt starts from the seeded
#                                  world (run_eval.py --reset-home calls it before each one,
#                                  and run_capability.py before each `checker.state` trial)
#   capability-daemon.sh check     ask whether a reset would be carried out; changes nothing
#   capability-daemon.sh run       up, run the capability tier, down; preserve its exit code
#
# Only the keeper `up` started (bin/eval_daemon_keeper.py) ever starts, stops or restores
# the daemon after `up`: it holds the daemon's environment, as this script built it, in
# its own memory (handed over a pipe, never a file), and the id of `up`'s snapshot.
# `reset` and `check` exit 3, with the reason and what to do from there, and replace
# nothing when no such keeper runs for the home (a daemon started by hand, say), when a
# daemon it did not start answers the home, when the snapshot was taken again since its
# `up`, or (FERMIX_CAP_PROJECT set) when the daemon exports to another Opik project.
#
# Override the home with FERMIX_CAP_HOME (leaf must contain 'eval' or 'e2e'; reset
# refuses any other home before it stops or touches anything: eval_home_state.py).
# CI knobs: FERMIX_CAP_PROJECT overrides the Opik project; FERMIX_CAP_SEED_ARGS
# passes extra flags to seed_capability_home.py (e.g. the explicit --provider/
# --model CI mode, or --cues for the cue suites); FERMIX_CAP_OPIK=0 starts the daemon without the Opik
# exporter (macOS smoke boxes have no Opik).
#
# The seed records the runners' fixture-server port in
# eval-fixtures/fixture_server.json, and the daemon starts with
# FERMIX_EVAL_FIXTURE_ORIGIN=http://127.0.0.1:<that port>, the one origin a dev
# build's web_fetch reads past its private-address guard, and where a dev build's
# phone calls go (the runners' simulated GPT-Live endpoint). A home without that
# manifest starts the daemon with the variable removed, inherited or not, so its
# web_fetch refuses loopback as every other Fermix does.
set -euo pipefail

HOME_DIR="${FERMIX_CAP_HOME:-$HOME/.fermix-capability-eval}"
PROJECT="${FERMIX_CAP_PROJECT:-fermix-capability-eval}"
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"      # benchmark/bin
BENCH="$(cd "$BIN_DIR/.." && pwd)"                            # benchmark
REPO_ROOT="$(cd "$BENCH/.." && pwd)"                          # umbrella root
PIDFILE="$HOME_DIR/daemon.pid"
KEEPER_PIDFILE="$HOME_DIR/keeper.pid"
KEEPER="$BIN_DIR/eval_daemon_keeper.py"
LOGFILE="$HOME_DIR/daemon.log"
READY_TIMEOUT="${READY_TIMEOUT:-90}"
REFUSED=3

FIXTURE_MANIFEST="$HOME_DIR/eval-fixtures/fixture_server.json"

log() { printf '\033[36m[cap-daemon]\033[0m %s\n' "$*" >&2; }

seed() {
  log "seeding disposable home $HOME_DIR"
  local -a seed_args=()
  if [ -n "${FERMIX_CAP_SEED_ARGS:-}" ]; then
    read -r -a seed_args <<<"$FERMIX_CAP_SEED_ARGS"
  fi
  "$BIN_DIR/seed_capability_home.py" "$HOME_DIR" ${seed_args[@]+"${seed_args[@]}"}
}

up() {
  # Up means a keeper answers AND its daemon does. Anything else of an earlier up (a
  # keeper whose daemon exited, a daemon whose keeper is gone, one started by hand) is
  # refused with what clears it; only a home where nothing runs is seeded and started.
  local found=0
  "$KEEPER" ask check "$HOME_DIR" --for-up ${FERMIX_CAP_PROJECT:+--project "$FERMIX_CAP_PROJECT"} \
    || found=$?
  case "$found" in
    0) log "daemon already up (keeper pid $(cat "$KEEPER_PIDFILE"))"; return 0 ;;
    4) ;;
    *) log "nothing was seeded or started (the reason and what to do are above)"
       return "$REFUSED" ;;
  esac
  seed
  rm -f "$HOME_DIR/daemon.sock"                    # nothing answers on it: stale
  log "compiling once so the readiness window stays tight"
  ( cd "$REPO_ROOT" && mix compile >/dev/null )
  # With --cues (FERMIX_CAP_SEED_ARGS) the cue suites' watchers and tasks are
  # memory.db rows, made through the product's own calls while the daemon is
  # still down (the only writer). Without it the seeder left no cue manifest and
  # the cue suites are held out as not evaluated.
  if [ -f "$HOME_DIR/eval-fixtures/cues.json" ]; then
    log "seeding the cue watchers and tasks (--cues)"
    ( cd "$REPO_ROOT" && FERMIX_HOME="$HOME_DIR" \
        mix run --no-start --no-compile benchmark/bin/seed_cues.exs )
  fi
  # With --computers, the computers suite's history notes are memory.db rows,
  # written the same way (M97 §8.4).
  if [ -f "$HOME_DIR/eval-fixtures/computers.json" ]; then
    log "seeding the computers' history notes (--computers)"
    ( cd "$REPO_ROOT" && FERMIX_HOME="$HOME_DIR" \
        mix run --no-start --no-compile benchmark/bin/seed_history.exs )
  fi
  # The world every `reset` puts back, taken while the daemon is still down.
  log "snapshotting the seeded state"
  "$BIN_DIR/eval_home_state.py" snapshot "$HOME_DIR"
  start_keeper
}

# The origin the manifest names, read by the runners' own reader of it
# (evallib.fixture_server.home_port), so the daemon and the runners never
# disagree on the port; a manifest it refuses stops the start.
fixture_origin() {
  ( cd "$BIN_DIR" && uv run --no-project python -c '
import sys
from evallib.fixture_server import ServerError, home_port
try:
    print(f"http://127.0.0.1:{home_port(sys.argv[1])}")
except ServerError as exc:
    sys.exit(f"capability-daemon: {exc}")
' "$HOME_DIR" )
}

start_keeper() {
  # Keep channels running (--no-web/--no-realtime only): the CLI-ask turn queue
  # is FermixChannels.Gateway.Queue, so --no-channels would break every turn. No
  # channel is configured in the seeded home, so no bot adapters actually poll.
  # The environment built here is the daemon's for its whole life: the keeper gets it,
  # starts the daemon with it, and starts it with it again on every reset. A fresh up
  # starts a new log; the keeper marks each start in it and appends.
  log "starting disposable daemon (no web/realtime); log: $LOGFILE"
  local -a opik_env=(FERMIX_OPIK_ENABLED=1 FERMIX_OPIK_PROJECT="$PROJECT")
  if [ "${FERMIX_CAP_OPIK:-1}" = "0" ]; then opik_env=(); fi
  # The fixture origin only from this home's manifest; never one the caller's
  # environment carries (`env -u` below drops it first).
  local -a fixture_env=()
  if [ -f "$FIXTURE_MANIFEST" ]; then
    local origin
    origin="$(fixture_origin)" || return 1
    fixture_env=(FERMIX_EVAL_FIXTURE_ORIGIN="$origin")
    log "web_fetch may read the fixture origin $origin"
  fi
  # With --cues the seeder leaves a stub `codex` in eval-bin for the follow-up
  # cases, and with --coding-signed-out a stub `claude` that fails every run as
  # signed out; first on the daemon's PATH, each is the CLI the daemon finds at boot.
  local daemon_path="$PATH"
  if [ -x "$HOME_DIR/eval-bin/codex" ] || [ -x "$HOME_DIR/eval-bin/claude" ]; then
    daemon_path="$HOME_DIR/eval-bin:$PATH"
  fi
  # With --phone-calls the phone engine's OpenAI key is the invented one the seed
  # stored; an OPENAI_API_KEY the caller's environment carries would overlay it at
  # boot (config/runtime.exs), so that home's daemon starts without it.
  local -a drop_env=(-u FERMIX_EVAL_FIXTURE_ORIGIN -u EVAL_KEEPER_ENV_END)
  if [ -f "$HOME_DIR/eval-fixtures/phone_calls.json" ]; then
    if [ ! -f "$FIXTURE_MANIFEST" ]; then
      log "refusing to start: phone calls are on but $FIXTURE_MANIFEST is missing, so the"
      log "daemon's calls would not reach the simulated endpoint; reseed the home"
      return 1
    fi
    drop_env+=(-u OPENAI_API_KEY)
    log "phone calls on: the daemon's OpenAI key is the seed's invented one, and its calls reach the fixture origin only"
  fi
  local -a daemon_env=("${drop_env[@]}"
    PATH="$daemon_path"
    FERMIX_HOME="$HOME_DIR"
    ${opik_env[@]+"${opik_env[@]}"}
    FERMIX_BROWSER_HEADLESS=1
    ${fixture_env[@]+"${fixture_env[@]}"})
  : >"$LOGFILE"
  # The keeper gets the daemon's environment on stdin, exactly as `env` builds it here
  # (`env -0`, through a pipe, then the EVAL_KEEPER_ENV_END entry it refuses a hand-over
  # without), and starts the daemon with that alone: never with its own, to which its
  # interpreter adds (uv run's venv, CPython's locale coercion).
  ( cd "$REPO_ROOT" && { env "${daemon_env[@]}" env -0; printf 'EVAL_KEEPER_ENV_END=1\0'; } \
      | exec "$KEEPER" serve "$HOME_DIR" --cwd "$REPO_ROOT" --ready-timeout "$READY_TIMEOUT" \
          -- mix fermix.dev --no-web --no-realtime ) >>"$LOGFILE" 2>&1 &
  local launcher=$!
  disown %% 2>/dev/null || true   # survive this shell exiting (up leaves it running)
  log "waiting for the daemon to answer its control socket (up to ${READY_TIMEOUT}s)"
  if ! "$KEEPER" ask check "$HOME_DIR" --wait-for "$launcher"; then
    log "daemon did not come up — last log lines:"
    tail -n 20 "$LOGFILE" >&2 || true
    return 1
  fi
  log "daemon ready (pid $(cat "$PIDFILE"))"
}

# Stop the process a pidfile names: SIGTERM, then SIGKILL after $2 seconds.
stop_pidfile() {
  local pidfile="$1" grace="$2" pid i
  [ -f "$pidfile" ] || return 0
  pid="$(cat "$pidfile")"
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    for ((i = 0; i < grace * 5; i++)); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.2
    done
    if kill -0 "$pid" 2>/dev/null; then
      log "pid $pid still alive after SIGTERM — SIGKILL"
      kill -KILL "$pid" 2>/dev/null || true
    fi
  fi
  rm -f "$pidfile"
}

down() {
  # The keeper first (it stops its daemon, waiting 15 s for it), then a daemon a keeper
  # killed outright left behind. The control socket goes only once nothing answers on it:
  # a daemon this script did not start keeps its socket, and with it the probe every
  # snapshot, restore and seed asks before it replaces anything.
  log "stopping the keeper and its daemon"
  stop_pidfile "$KEEPER_PIDFILE" 25
  stop_pidfile "$PIDFILE" 15
  rm -f "$HOME_DIR/keeper.sock"
  # Whatever answers the control socket now, whoever started it (the keeper asks it).
  local pid found=0
  pid="$("$KEEPER" answering "$HOME_DIR")" || found=$?
  case "$found" in
    0) log "a daemon this script did not start still answers for $HOME_DIR (pid $pid):"
       log "left it and its socket alone; stop it (kill $pid), then run down again"
       return "$REFUSED" ;;
    4) ;;
    *) log "a daemon this script did not start still answers for $HOME_DIR (above): left"
       log "it and its socket alone; find it (lsof $HOME_DIR/daemon.sock), stop it, then run down again"
       return "$REFUSED" ;;
  esac
  rm -f "$HOME_DIR/daemon.sock"
  log "stopped"
}

# The disposable-home guard and the snapshot's presence first, then the keeper `up`
# started answers: it refuses (exit 3, the reason on stderr) before it stops anything.
ask_keeper() {
  "$BIN_DIR/eval_home_state.py" check "$HOME_DIR" >/dev/null || return "$REFUSED"
  "$KEEPER" ask "$1" "$HOME_DIR" ${FERMIX_CAP_PROJECT:+--project "$FERMIX_CAP_PROJECT"}
}

reset() {
  log "asking the keeper to restore the seeded state and restart the daemon"
  ask_keeper reset
}

check() { ask_keeper check; }

# The EXIT trap of `run`: a teardown that fails (a daemon this script did not start
# still answering, exit 3) is said, and never replaces the runner's exit code.
teardown() {
  down || log "down exited $? (its reason above); the run's own exit code stands"
}

run() {
  trap teardown EXIT
  # The private holdout (config private_suites.dir) joins every local run: synced
  # before seeding so its skills are in the home, scored after the public sweep as its
  # own :private row. CAPABILITY_PRIVATE=0 leaves it out (e.g. no access to its repo).
  local private_dir=""
  if [ "${CAPABILITY_PRIVATE:-1}" != "0" ]; then
    log "syncing the private suites (CAPABILITY_PRIVATE=0 leaves them out)"
    if ! private_dir="$(cd "$BENCH" && uv run bin/private_suites.py sync)"; then
      log "private suite sync failed (reason above); nothing was started"
      return 3
    fi
    private_dir="${private_dir##*$'\n'}"     # the dir is the last line
    FERMIX_CAP_SEED_ARGS="${FERMIX_CAP_SEED_ARGS:-} --private-dir $private_dir"
  fi
  up
  log "verifying preconditions (Opik + daemon)"
  local result=0
  ( cd "$BENCH" && FERMIX_EVAL_HOME="$HOME_DIR" OPIK_PROJECT="$PROJECT" \
      uv run bin/run_capability.py --check ) || result=$?
  if [ "$result" -ne 0 ]; then
    log "capability preflight exited with code $result"
    return "$result"
  fi
  log "running the full capability sweep against the disposable daemon"
  ( cd "$BENCH" && FERMIX_EVAL_HOME="$HOME_DIR" OPIK_PROJECT="$PROJECT" \
      CONFIRM_DAEMON_ISOLATED=1 CONFIRM_ISOLATED_ENV=1 CONFIRM_COST=1 \
      "$BIN_DIR/tier.sh" capability ) || result=$?
  log "capability runner exited with code $result (0=green, 2=selection, 3=preconditions, 4=invalid, 5=release gate red)"
  if [ -n "$private_dir" ]; then
    log "running the private suites from $private_dir"
    local private_result=0
    ( cd "$BENCH" && FERMIX_EVAL_HOME="$HOME_DIR" OPIK_PROJECT="$PROJECT" \
        CONFIRM_DAEMON_ISOLATED=1 CONFIRM_ISOLATED_ENV=1 CONFIRM_COST=1 \
        "$BIN_DIR/tier.sh" capability-private ) || private_result=$?
    log "private runner exited with code $private_result"
    # The run's code is the worse of the two: invalid, preconditions, selection,
    # then a red gate, so a broken private measurement is never hidden by a public one.
    local code
    for code in 4 3 2 5; do
      if [ "$result" = "$code" ] || [ "$private_result" = "$code" ]; then
        result="$code"
        break
      fi
    done
  fi
  return "$result"
}

case "${1:-run}" in
  up)       up ;;
  down)     trap - EXIT; down ;;
  reset)    reset ;;
  check)    check ;;
  run)      run ;;
  *)        echo "usage: $(basename "$0") [up|down|reset|check|run]" >&2; exit 2 ;;
esac
