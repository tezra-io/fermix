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
#   capability-daemon.sh up     seed + start (background) + wait ready
#   capability-daemon.sh down    stop + clean the control socket
#   capability-daemon.sh run     up, run the full `make capability` sweep, down
#
# Override the home with FERMIX_CAP_HOME (leaf must contain 'eval' or 'e2e').
# CI knobs: FERMIX_CAP_PROJECT overrides the Opik project; FERMIX_CAP_SEED_ARGS
# passes extra flags to seed_capability_home.py (e.g. the explicit --provider/
# --model CI mode); FERMIX_CAP_OPIK=0 starts the daemon without the Opik
# exporter (macOS smoke boxes have no Opik).
set -euo pipefail

HOME_DIR="${FERMIX_CAP_HOME:-$HOME/.fermix-capability-eval}"
PROJECT="${FERMIX_CAP_PROJECT:-fermix-capability-eval}"
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"      # benchmark/bin
BENCH="$(cd "$BIN_DIR/.." && pwd)"                            # benchmark
REPO_ROOT="$(cd "$BENCH/.." && pwd)"                          # umbrella root
PIDFILE="$HOME_DIR/daemon.pid"
LOGFILE="$HOME_DIR/daemon.log"
READY_TIMEOUT="${READY_TIMEOUT:-90}"

log() { printf '\033[36m[cap-daemon]\033[0m %s\n' "$*" >&2; }

running() { [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }

seed() {
  log "seeding disposable home $HOME_DIR"
  local -a seed_args=()
  if [ -n "${FERMIX_CAP_SEED_ARGS:-}" ]; then
    read -r -a seed_args <<<"$FERMIX_CAP_SEED_ARGS"
  fi
  "$BIN_DIR/seed_capability_home.py" "$HOME_DIR" ${seed_args[@]+"${seed_args[@]}"}
}

up() {
  if running; then
    log "daemon already up (pid $(cat "$PIDFILE"))"
    return 0
  fi
  seed
  rm -f "$HOME_DIR/daemon.sock"                    # drop any stale socket
  log "compiling once so the readiness window stays tight"
  ( cd "$REPO_ROOT" && mix compile >/dev/null )
  # Keep channels running (--no-web/--no-realtime only): the CLI-ask turn queue
  # is FermixChannels.Gateway.Queue, so --no-channels would break every turn. No
  # channel is configured in the seeded home, so no bot adapters actually poll.
  log "starting disposable daemon (no web/realtime); log: $LOGFILE"
  local -a opik_env=(FERMIX_OPIK_ENABLED=1 FERMIX_OPIK_PROJECT="$PROJECT")
  if [ "${FERMIX_CAP_OPIK:-1}" = "0" ]; then opik_env=(); fi
  ( cd "$REPO_ROOT" && exec env \
      FERMIX_HOME="$HOME_DIR" \
      ${opik_env[@]+"${opik_env[@]}"} \
      FERMIX_BROWSER_HEADLESS=1 \
      mix fermix.dev --no-web --no-realtime ) >"$LOGFILE" 2>&1 &
  echo $! >"$PIDFILE"
  disown %% 2>/dev/null || true   # survive this shell exiting (up leaves it running)
  log "waiting for the control socket (up to ${READY_TIMEOUT}s)"
  local i
  for ((i = 0; i < READY_TIMEOUT; i++)); do
    if FERMIX_HOME="$HOME_DIR" "$BIN_DIR/fermix-shim" status --json >/dev/null 2>&1; then
      log "daemon ready (pid $(cat "$PIDFILE"))"
      return 0
    fi
    if ! running; then
      log "daemon exited during boot — last log lines:"
      tail -n 20 "$LOGFILE" >&2 || true
      return 1
    fi
    sleep 1
  done
  log "daemon did not become ready within ${READY_TIMEOUT}s — see $LOGFILE"
  return 1
}

down() {
  if [ -f "$PIDFILE" ]; then
    local pid
    pid="$(cat "$PIDFILE")"
    if kill -0 "$pid" 2>/dev/null; then
      log "stopping daemon (pid $pid)"
      kill -TERM "$pid" 2>/dev/null || true
      local i
      for ((i = 0; i < 15; i++)); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
      done
      if kill -0 "$pid" 2>/dev/null; then
        log "daemon still alive after SIGTERM — SIGKILL fallback"
        kill -KILL "$pid" 2>/dev/null || true
      fi
    fi
    rm -f "$PIDFILE"
  fi
  rm -f "$HOME_DIR/daemon.sock"
  log "stopped"
}

run() {
  trap down EXIT
  up
  log "verifying preconditions (Opik + daemon)"
  ( cd "$BENCH" && FERMIX_EVAL_HOME="$HOME_DIR" OPIK_PROJECT="$PROJECT" make check )
  log "running the full capability sweep against the disposable daemon"
  ( cd "$BENCH" && FERMIX_EVAL_HOME="$HOME_DIR" OPIK_PROJECT="$PROJECT" \
      CONFIRM_DAEMON_ISOLATED=1 CONFIRM_ISOLATED_ENV=1 CONFIRM_COST=1 make capability )
}

case "${1:-run}" in
  up)   up ;;
  down) trap - EXIT; down ;;
  run)  run ;;
  *)    echo "usage: $(basename "$0") [up|down|run]" >&2; exit 2 ;;
esac
