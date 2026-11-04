#!/usr/bin/env bash
# A throwaway Fermix daemon on this Mac, for testing Always On (moving the home
# to a server and back) with nothing to set up by hand.
#
#   always_on_test_daemon.sh up [--release X]   install the published, signed
#                                               macOS release X (the latest when
#                                               none is named) with a home of its
#                                               own, and open its web setup
#   always_on_test_daemon.sh status             what runs, where, and the home's
#                                               Always On screen
#   always_on_test_daemon.sh down               stop it and remove all of it
#
# Everything the owner does after `up` (model key, the code for their own
# server, move, move back) is done in the web setup.
#
# What keeps it apart from the owner's own Fermix:
#   * Root: ~/fermix-always-on-test (bin/, home/), carrying a marker file. Only
#     a root with that marker is ever removed.
#   * Keychain: the home's `[fermix_core] profile` is always-on-test, so every
#     secret it stores is named fermix:always-on-test:<NAME>, never the
#     unprefixed names of the default profile the owner's home uses.
#   * Ports: the web setup, the phone listener and the cue door get a group of
#     three free ports of their own (base, base+1, base+2).
#   * Service: a move needs an engine that restarts itself, which for the
#     standalone binary is its own launchd agent, io.tezra.fermix. `up` runs
#     only while that label is free and never touches the Fermix app's agents.
#   * Runtime: the binary is a Burrito wrapper that unpacks into
#     ~/Library/Application Support/.burrito/fermix_erts-<erts>_<version> and,
#     on every launch, deletes the unpacked runtime of any older fermix there.
#     The agent the engine writes carries no install-dir override, so the
#     daemon cannot be kept out of that directory; `up` refuses instead while
#     another fermix is on PATH or runs from it, or while this version is
#     already unpacked there, and `down` removes the runtime `up` unpacked.
#
# While it runs, the Fermix app's Doctor lists io.tezra.fermix as another
# Fermix service on this Mac; that goes away with `down`.
#
# A server installs exactly the published, signed release whose version the
# desktop reports, so this runs a published release, verified against its
# sha256 sidecar and the cosign identity of release.yml on refs/tags/vX.
#
# Exit status: 0 done, 1 refused or failed (one sentence on stderr), 2 usage.

set -euo pipefail

readonly REPO="tezra-io/fermix"
readonly LABEL="io.tezra.fermix"
readonly PROFILE="always-on-test"
readonly MARKER_NAME=".always-on-test-daemon"
readonly MARKER_TEXT="This directory is a throwaway Fermix made by scripts/always_on_test_daemon.sh; its down removes it."
readonly COSIGN_ISSUER="https://token.actions.githubusercontent.com"
readonly COSIGN_IDENTITY_PREFIX="https://github.com/${REPO}/.github/workflows/release.yml@refs/tags/v"
# One probe of the web listener a second, so about a minute.
readonly HEALTH_WAIT_ATTEMPTS=60
readonly MANIFEST_MAX_SECONDS=60
readonly DOWNLOAD_MAX_SECONDS=600
# Each base is a group: web setup, phone listener, cue door. None is 4030-4032,
# the defaults every other home starts on.
readonly PORT_BASES="4730 4740 4750 4760 4770 4780 4790"
# A delete-generic-password removes one item; more than this many under one
# name is not something this script made.
readonly MAX_DELETES_PER_ITEM=8

prog="scripts/always_on_test_daemon.sh"
root_made=0

fail() {
  if [ "$root_made" -eq 1 ]; then
    printf '%s: %s; run %s down to remove what up left.\n' "$prog" "$1" "$prog" >&2
  else
    printf '%s: %s.\n' "$prog" "$1" >&2
  fi
  exit 1
}

usage() {
  cat >&2 <<USAGE
usage: $prog up [--release X]
       $prog status
       $prog down
USAGE
  exit 2
}

say() { printf '%s\n' "$*"; }

case "${HOME:-}" in
  /?*) ;;
  *) printf '%s: HOME must be an absolute path.\n' "$prog" >&2; exit 1 ;;
esac

readonly ROOT="$HOME/fermix-always-on-test"
readonly BIN="$ROOT/bin/fermix"
readonly HOME_DIR="$ROOT/home"
readonly STATE="$ROOT/state"
readonly PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
readonly BURRITO_BASE="$HOME/Library/Application Support/.burrito"

work=""
cleanup() { if [ -n "$work" ]; then rm -rf -- "$work"; fi; }
trap cleanup EXIT

# ── the engine, and the two files read from it ────────────────────────────────

# Every engine call runs in one fixed environment: this home, the account's
# HOME and a bare PATH. Nothing from the caller's shell (PORT, a FERMIX_*
# switch, a Burrito install-dir override, the Opik exporter) reaches the CLI or
# the agent it writes.
engine() {
  env -i HOME="$HOME" USER="${USER:-$(id -un)}" LOGNAME="${USER:-$(id -un)}" \
    TMPDIR="${TMPDIR:-/tmp}" LANG=en_US.UTF-8 PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    FERMIX_HOME="$HOME_DIR" "$BIN" "$@"
}

# One value of a JSON or plist file by its keys: a string as it is, null as
# `null`, anything else as JSON. A key that is not there exits 3.
field() {
  uv run --no-project python -I -c '
import json, plistlib, sys
path, kind, keys = sys.argv[1], sys.argv[2], sys.argv[3:]
with open(path, "rb") as stream:
    value = json.load(stream) if kind == "json" else plistlib.load(stream)
for key in keys:
    if isinstance(value, dict) and key in value:
        value = value[key]
    elif isinstance(value, list) and key.isdigit() and int(key) < len(value):
        value = value[int(key)]
    else:
        sys.exit(3)
print("null" if value is None else value if isinstance(value, str) else json.dumps(value))
' "$@"
}

# ── this script's own root ────────────────────────────────────────────────────

marked() {
  [ -d "$ROOT" ] && [ ! -L "$ROOT" ] && [ -f "$ROOT/$MARKER_NAME" ] &&
    [ "$(cat "$ROOT/$MARKER_NAME")" = "$MARKER_TEXT" ]
}

require_marked_root() {
  [ -e "$ROOT" ] || [ -L "$ROOT" ] || fail "no throwaway daemon is set up: $ROOT does not exist"
  marked || fail "$ROOT has no marker of this script, so it is not this script's and is left alone"
}

state_get() {
  [ -f "$STATE" ] || return 0
  awk -v key="$1" 'index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }' "$STATE"
}

# ── the host ──────────────────────────────────────────────────────────────────

require_macos() {
  [ "$(uname -s)" = Darwin ] || fail "this runs only on a Mac: it installs a launchd agent and uses the login Keychain"
}

macos_arch() {
  case "$(uname -m)" in
    arm64) say aarch64 ;;
    x86_64) say x86_64 ;;
    *) fail "Fermix publishes no macOS release for $(uname -m)" ;;
  esac
}

require_tools() {
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || fail "$tool is not on PATH"
  done
}

job_loaded() { launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; }

port_listening() { lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }

# The first process whose program runs out of `$1`, or nothing. awk reads all
# of ps's output, so no early exit breaks the pipe under pipefail.
running_from() {
  ps -axww -o command= | awk -v prefix="$1" 'index($0, prefix) == 1 && found == "" { found = $0 } END { if (found != "") print found }'
}

valid_version() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

# ── up ────────────────────────────────────────────────────────────────────────

refuse_taken_label() {
  if [ -e "$ROOT" ] || [ -L "$ROOT" ]; then
    if marked; then fail "a throwaway daemon is already set up at $ROOT; run $prog down first"; fi
    fail "$ROOT exists and has no marker of this script, so it is left alone; move it away first"
  fi
  if job_loaded; then fail "launchd already has $LABEL loaded, and this script runs only where that label is free"; fi
  [ ! -e "$PLIST" ] || fail "$PLIST already exists, and this script runs only where that label is free"
}

refuse_shared_runtime() {
  local other running
  other="$(command -v fermix || true)"
  [ -z "$other" ] || fail "another fermix is installed at $other, and its runtime would share $BURRITO_BASE with this one"
  running="$(running_from "$BURRITO_BASE/")"
  [ -z "$running" ] || fail "a fermix runs from $BURRITO_BASE ($running), and this one would share that runtime directory"
}

refuse_unpacked_runtime() {
  local found
  [ -d "$BURRITO_BASE" ] || return 0
  found="$(find "$BURRITO_BASE" -mindepth 1 -maxdepth 1 -name "fermix_erts-*_$1" -print -quit)"
  [ -z "$found" ] || fail "a Fermix $1 runtime is already unpacked at $found, and this binary would run it instead of its own bytes"
}

latest_version() {
  local manifest="$work/latest/releases.json" version
  mkdir "$work/latest"
  curl -fsSL --max-time "$MANIFEST_MAX_SECONDS" -o "$manifest" \
    "https://github.com/$REPO/releases/latest/download/releases.json" ||
    fail "could not fetch the latest release's manifest from GitHub"
  version="$(awk '/"latest":/ { gsub(/[",]/, ""); print $2; exit }' "$manifest")"
  valid_version "$version" || fail "the latest release's manifest names no version"
  say "$version"
}

pick_port() {
  local base
  for base in $PORT_BASES; do
    if ! port_listening "$base" && ! port_listening "$((base + 1))" && ! port_listening "$((base + 2))"; then
      say "$base"
      return 0
    fi
  done
  fail "no group of three free ports among the bases $PORT_BASES"
}

# Downloads the release's macOS binary for this Mac with its three sidecars,
# each into the one new directory, and leaves it there only once both checks
# pass.
download_release() {
  local version="$1" artifact="$2" dir="$work/release" name
  local base="https://github.com/$REPO/releases/download/v$version"
  mkdir "$dir"
  for name in "$artifact" "$artifact.sha256" "$artifact.sig" "$artifact.pem"; do
    curl -fsSL --max-time "$DOWNLOAD_MAX_SECONDS" -o "$dir/$name" "$base/$name" ||
      fail "could not download $name of release $version from GitHub"
  done
  verify_sha256 "$dir" "$artifact"
  verify_signature "$dir" "$artifact" "$version"
}

verify_sha256() {
  local expected actual
  expected="$(awk -v name="$2" 'NF == 2 && $2 == name { print $1; exit }' "$1/$2.sha256")"
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || fail "the sha256 sidecar of $2 holds no digest for it"
  actual="$(shasum -a 256 "$1/$2" | awk '{ print $1 }')"
  [ "$actual" = "$expected" ] || fail "$2 does not match its sha256 sidecar: expected $expected, downloaded $actual"
}

verify_signature() {
  local log="$work/cosign.log"
  if ! cosign verify-blob --certificate "$1/$2.pem" --signature "$1/$2.sig" \
    --certificate-identity "$COSIGN_IDENTITY_PREFIX$3" \
    --certificate-oidc-issuer "$COSIGN_ISSUER" "$1/$2" >"$log" 2>&1; then
    cat "$log" >&2
    fail "cosign did not verify $2 as signed by release.yml on refs/tags/v$3"
  fi
}

render_config() {
  cat <<CONFIG
# A throwaway home for testing Always On, written by scripts/always_on_test_daemon.sh.
# Its own keychain namespace, so no secret saved here replaces another home's.
[fermix_core]
profile = "$PROFILE"

# Always On, which a release build offers only where this says so.
[fermix_core.always_on]
enabled = true

# Its own ports: the cue door, the phone listener and the web setup.
[fermix_core.cues]
door_port = $(($1 + 2))

[fermix_channels.mobile]
port = $(($1 + 1))

[fermix_web]
port = $1
CONFIG
}

make_root() {
  local version="$1" port="$2" binary="$3"
  mkdir -m 700 "$ROOT"
  root_made=1
  printf '%s\n' "$MARKER_TEXT" >"$ROOT/$MARKER_NAME"
  mkdir -m 700 "$ROOT/bin" "$HOME_DIR"
  cp "$binary" "$BIN"
  chmod 755 "$BIN"
  render_config "$port" >"$HOME_DIR/config.toml"
  printf 'version=%s\nport=%s\n' "$version" "$port" >"$STATE"
}

# Where the wrapper unpacks this version, asked of the wrapper itself before
# its first launch (`maintenance directory` unpacks nothing).
record_runtime() {
  local runtime
  runtime="$(engine maintenance directory)" || fail "the binary did not say where it unpacks"
  runtime="${runtime%%$'\n'*}"
  case "$runtime" in
    "$BURRITO_BASE"/fermix_erts-*_"$1") ;;
    *) fail "the binary unpacks into ${runtime:-nowhere it named}, not a fermix_erts-*_$1 directory under $BURRITO_BASE" ;;
  esac
  printf 'runtime=%s\n' "$runtime" >>"$STATE"
  note_older_runtimes "$runtime"
}

note_older_runtimes() {
  local other
  [ -d "$BURRITO_BASE" ] || return 0
  find "$BURRITO_BASE" -mindepth 1 -maxdepth 1 -name 'fermix_erts-*' | sort | while IFS= read -r other; do
    [ "$other" = "$1" ] ||
      say "Note: Burrito deletes $other on this binary's first launch if it is an older version; no fermix on PATH or running uses it."
  done
}

# `fermix setup --web` is the engine's own way to bring a standalone up: it
# writes and loads the launchd agent, starts it, mints a one-use setup token
# and waits for the daemon. The browser is opened below, once this script has
# seen the daemon answer as the version it installed.
start_service() {
  local port="$1" out="$work/setup.out" url
  if ! engine setup --web --user --no-browser >"$out" 2>&1; then
    cat "$out" >&2
    fail "fermix setup did not install and start the service"
  fi
  url="$(awk -v origin="http://127.0.0.1:$port/setup?t=" 'index($1, origin) == 1 { print $1; exit }' "$out")"
  [ -n "$url" ] || { cat "$out" >&2; fail "fermix setup printed no setup address on port $port"; }
  say "$url"
}

wait_for_health() {
  local port="$1" version="$2" attempt body
  for ((attempt = 1; attempt <= HEALTH_WAIT_ATTEMPTS; attempt++)); do
    if body="$(curl -fsS --max-time 2 "http://127.0.0.1:$port/health/live" 2>/dev/null)"; then
      case "$body" in
        *"\"version\":\"$version\""*) return 0 ;;
        *) fail "port $port answers, but not as Fermix $version: $body" ;;
      esac
    fi
    sleep 1
  done
  fail "the daemon did not answer on port $port after $HEALTH_WAIT_ATTEMPTS tries; read $HOME_DIR/logs/fermix.log"
}

own_service() {
  [ -f "$PLIST" ] &&
    [ "$(field "$PLIST" plist ProgramArguments 0)" = "$BIN" ] &&
    [ "$(field "$PLIST" plist EnvironmentVariables FERMIX_HOME)" = "$HOME_DIR" ]
}

require_running_service() {
  own_service || fail "$PLIST does not run $BIN from $HOME_DIR"
  job_loaded || fail "launchd has no $LABEL loaded"
}

parse_up() {
  release=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --release)
        [ "$#" -ge 2 ] || usage
        release="${2#v}"
        valid_version "$release" || usage
        shift 2
        ;;
      *) usage ;;
    esac
  done
}

cmd_up() {
  local version arch port url
  parse_up "$@"
  require_macos
  require_tools curl shasum cosign launchctl lsof open uv
  arch="$(macos_arch)"
  refuse_taken_label
  refuse_shared_runtime
  work="$(mktemp -d)"
  version="$release"
  [ -n "$version" ] || version="$(latest_version)"
  refuse_unpacked_runtime "$version"
  port="$(pick_port)"
  download_release "$version" "fermix_macos_$arch"
  make_root "$version" "$port" "$work/release/fermix_macos_$arch"
  record_runtime "$version"
  url="$(start_service "$port")"
  wait_for_health "$port" "$version"
  require_running_service
  open "$url"
  say "Fermix $version (published, sha256 and signature verified) runs as $LABEL from $ROOT."
  say "Web setup (opened in your browser): $url"
  say "Home: $HOME_DIR, keychain profile $PROFILE, ports $port-$((port + 2))."
  say "Take it all down with: $prog down"
}

# ── status ────────────────────────────────────────────────────────────────────

service_line() {
  local out="$work/launchctl.out"
  if ! launchctl print "gui/$(id -u)/$LABEL" >"$out" 2>&1; then
    say "$LABEL is not loaded"
    return 0
  fi
  awk -v label="$LABEL" '
    /^\tstate = / && state == "" { state = $3 }
    /^\tpid = / && pid == "" { pid = $3 }
    END { printf "%s %s%s\n", label, (state == "" ? "loaded" : state), (pid == "" ? "" : " (pid " pid ")") }
  ' "$out"
}

health_line() {
  local body
  if body="$(curl -fsS --max-time 2 "http://127.0.0.1:$1/health/live" 2>/dev/null)"; then
    say "answering: $body"
  else
    say "not answering on port $1"
  fi
}

cmd_status() {
  local port code=0
  [ "$#" -eq 0 ] || usage
  require_macos
  require_tools curl launchctl uv
  require_marked_root
  work="$(mktemp -d)"
  port="$(state_get port)"
  say "Root:      $ROOT"
  say "Release:   $(state_get version)"
  say "Home:      $HOME_DIR (keychain profile $PROFILE)"
  say "Setup:     http://127.0.0.1:$port/setup (signed in in the browser up opened;"
  say "           a new sign-in link is fermix setup --web in this home, which restarts it)"
  say "Service:   $(service_line)"
  say "Agent:     $(if own_service; then say "$PLIST runs $BIN"; else say "no agent of this root's at $PLIST"; fi)"
  say "Health:    $(health_line "$port")"
  say "Always On (fermix home status):"
  engine home status >"$work/home.out" 2>&1 || code=$?
  # A usage error (2) is one line followed by the whole usage; the line says it.
  if [ "$code" -eq 2 ]; then
    sed -n '1s/^/  /p' "$work/home.out"
  else
    sed 's/^/  /' "$work/home.out"
  fi
  [ "$code" -eq 0 ] || say "  (exit $code)"
}

# ── down ──────────────────────────────────────────────────────────────────────

# The states in which Always On holds no server and no move: nothing set up, or
# a code for the owner's server that no server used yet.
holds_nothing() {
  case "$1" in
    off | connect) return 0 ;;
    *) return 1 ;;
  esac
}

# A build without Always On holds no server: one that refuses it by name, or
# one older than it, which has no `home` verb at all. Anything else this cannot
# read keeps the home.
refuse_held_server() {
  local out="$work/home.json" err="$work/home.err" code=0
  engine home status --json >"$out" 2>"$err" || code=$?
  case "$code" in
    0) check_screen "$out" ;;
    1)
      [ "$(screen_field "$out" error code)" = always_on_unavailable ] ||
        fail "fermix home status refused: $(screen_field "$out" error sentence)"
      say "Fermix $(state_get version) serves no Always On here, so it holds no server."
      ;;
    2)
      [ "$(head -n 1 "$err")" = "fermix: unknown command: home" ] ||
        { cat "$err" >&2; fail "fermix home status did not answer"; }
      say "Fermix $(state_get version) predates Always On, so it holds no server."
      ;;
    *) cat "$err" >&2; fail "fermix home status exited $code" ;;
  esac
}

# One field of the `fermix home status --json` envelope, or a refusal naming it.
screen_field() {
  field "$1" json "${@:2}" || fail "fermix home status --json answered no ${*:2}"
}

check_screen() {
  local role state move sentence
  role="$(screen_field "$1" result role)"
  state="$(screen_field "$1" result summary state)"
  move="$(screen_field "$1" result move)"
  sentence="$(screen_field "$1" result summary sentence)"
  if [ "$role" = primary ] && [ "$move" = null ] && holds_nothing "$state"; then
    say "Always On holds no server here ($state)."
    return 0
  fi
  fail "Always On says \"$sentence\" ($role, $state); move back or cancel in the web setup (http://127.0.0.1:$(state_get port)/setup) first, then run $prog down again"
}

# The service is this root's or absent; another's is never touched.
require_own_or_no_service() {
  if [ -e "$PLIST" ]; then
    own_service || fail "$PLIST does not run $BIN from $HOME_DIR, so it is not this root's and is left alone"
    return 0
  fi
  if job_loaded; then fail "launchd has $LABEL loaded with no $PLIST, so it is not this root's and is left alone"; fi
}

stop_service() {
  if [ -e "$PLIST" ]; then
    engine service uninstall --user || fail "fermix service uninstall did not remove $LABEL"
  fi
  if job_loaded; then fail "launchd still has $LABEL loaded after the uninstall"; fi
  [ ! -e "$PLIST" ] || fail "$PLIST is still there after the uninstall"
}

# The names of the Keychain items under this home's profile, one a line. The
# dump is the items' attributes only: without -d it carries no secret.
keychain_items() {
  local dump
  dump="$(security dump-keychain 2>/dev/null)" || fail "could not list the login Keychain's items"
  printf '%s\n' "$dump" | awk -v prefix="\"svce\"<blob>=\"fermix:$PROFILE:" '
    index($0, prefix) { line = $0; sub(/^[^=]*="/, "", line); sub(/"$/, "", line); print line }
  ' | sort -u
}

delete_item() {
  local tries=0 code
  while [ "$tries" -lt "$MAX_DELETES_PER_ITEM" ]; do
    code=0
    security delete-generic-password -a fermix -s "$1" >/dev/null 2>&1 || code=$?
    case "$code" in
      0) tries=$((tries + 1)) ;;
      44) return 0 ;;
      *) fail "security could not delete the Keychain item $1 (exit $code)" ;;
    esac
  done
  fail "more than $MAX_DELETES_PER_ITEM Keychain items are named $1"
}

remove_keychain_items() {
  local items item left count=0
  items="$(keychain_items)"
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    delete_item "$item"
    count=$((count + 1))
  done <<<"$items"
  left="$(keychain_items)"
  [ -z "$left" ] || fail "the Keychain item ${left%%$'\n'*} is still there; it is not stored under the fermix account"
  say "Removed $count Keychain items of profile $PROFILE."
}

# The unpacked runtime `up` recorded, removed by the wrapper's own verb. `up`
# refused to start while it already existed, so it is this root's.
remove_runtime() {
  local runtime
  runtime="$(state_get runtime)"
  [ -n "$runtime" ] || return 0
  case "$runtime" in
    "$BURRITO_BASE"/fermix_erts-*) ;;
    *) fail "the recorded runtime $runtime is not under $BURRITO_BASE, so it is left alone" ;;
  esac
  [ -e "$runtime" ] || return 0
  [ -z "$(running_from "$runtime/")" ] || fail "a process still runs from $runtime, so it is left alone"
  engine maintenance uninstall <<<"y" >/dev/null 2>&1 || fail "fermix maintenance uninstall failed"
  [ ! -e "$runtime" ] || fail "$runtime is still there after fermix maintenance uninstall"
  say "Removed the unpacked runtime $runtime."
}

# A root whose binary never ran holds no home to protect.
require_readable_home() {
  [ ! -e "$BIN" ] || return 0
  [ ! -e "$HOME_DIR/memory.db" ] || fail "$BIN is gone but its home ran, so this home's Always On cannot be read"
}

cmd_down() {
  [ "$#" -eq 0 ] || usage
  require_macos
  require_tools launchctl security uv
  if [ ! -e "$ROOT" ] && [ ! -L "$ROOT" ]; then
    if [ -e "$PLIST" ] || job_loaded; then fail "$LABEL is installed but $ROOT does not exist, so it is not this script's and is left alone"; fi
    say "Nothing to take down: $ROOT does not exist."
    return 0
  fi
  require_marked_root
  work="$(mktemp -d)"
  require_own_or_no_service
  require_readable_home
  if [ -e "$BIN" ]; then refuse_held_server; fi
  stop_service
  remove_keychain_items
  if [ -e "$BIN" ]; then remove_runtime; fi
  marked || fail "$ROOT lost its marker, so it is left alone"
  rm -rf -- "$ROOT"
  [ ! -e "$ROOT" ] || fail "$ROOT is still there"
  say "Removed $ROOT; $LABEL is uninstalled."
}

main() {
  [ "$#" -ge 1 ] || usage
  local command="$1"
  shift
  case "$command" in
    up) cmd_up "$@" ;;
    status) cmd_status "$@" ;;
    down) cmd_down "$@" ;;
    *) usage ;;
  esac
}

main "$@"
