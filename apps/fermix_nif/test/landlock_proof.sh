#!/usr/bin/env bash
# Prove the fermix_landlock shim against the running Linux kernel
# (OS_SANDBOX_ENFORCEMENT stage B, M75 D15).
#
# Usage: apps/fermix_nif/test/landlock_proof.sh [SHIM]
#
# SHIM is a built fermix_landlock. Without it the script builds one from
# c_src/fermix_landlock.c with cc under the release's strict flags, plus two
# test builds: one that reports ABI 2, which proves the refusal of a kernel
# before 6.2 on any kernel, and one that reports ABI 4, which proves that the
# restrictions of ABI 5 and 6 are asked only of a kernel that has them.
#
# It lays out a Fermix home in a scratch folder and carves rules the way
# `FermixCore.Sandbox.Landlock` does for `strict`: every folder above a
# protected path gets only `l`, its other entries are granted whole, and the
# workspace and a temp stand-in are writable. Then it runs each case under the
# shim and checks the kernel's answer. Running as root (a container), it also
# proves the real /run/fermix. It also proves the command runs in a session
# of its own, without its caller's terminal, and that a signal to the process
# group whose id is the command's pid (what kill_pgid/2 sends) reaches what it
# started. Exits 1 when any case does not hold, and on a host without
# Landlock ABI 3: this is the gate that says so. Needs perl, and setsid and
# script from util-linux.
set -euo pipefail

for tool in perl setsid script; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: the proof needs $tool" >&2; exit 1; }
done

nif_dir="$(cd "$(dirname "$0")/.." && pwd -P)"
work="$(mktemp -d "${TMPDIR:-/tmp}/fermix-landlock-proof.XXXXXX")"
work="$(cd "$work" && pwd -P)"
case "$work" in
  */fermix-landlock-proof.*) ;;
  *) echo "error: unexpected scratch folder $work" >&2; exit 1 ;;
esac
cleanup() {
  if [ -n "${listener:-}" ]; then kill "$listener" 2>/dev/null || true; fi
  chmod -R u+w "$work" 2>/dev/null || true
  rm -rf -- "$work"
  if [ -n "${run_dir:-}" ]; then rm -rf -- "$run_dir"; fi
}
trap cleanup EXIT

flags=(-std=c99 -O2 -Wall -Wextra -Werror)
if [ "$#" -ge 1 ]; then
  shim="$1"
else
  shim="$work/fermix_landlock"
  cc "${flags[@]}" "$nif_dir/c_src/fermix_landlock.c" -o "$shim"
fi
shim_abi2="$work/fermix_landlock_abi2"
cc "${flags[@]}" -DFERMIX_LANDLOCK_TEST_ABI=2 "$nif_dir/c_src/fermix_landlock.c" -o "$shim_abi2"
shim_abi4="$work/fermix_landlock_abi4"
cc "${flags[@]}" -DFERMIX_LANDLOCK_TEST_ABI=4 "$nif_dir/c_src/fermix_landlock.c" -o "$shim_abi4"

if ! abi_line="$("$shim" --abi 2>&1)"; then
  echo "error: this kernel cannot hold commands: $abi_line" >&2
  exit 1
fi
abi="${abi_line##* }"
echo "kernel $(uname -r), $abi_line"

# ── the layout ──────────────────────────────────────────────────────────────
base="$work/tree"
home="$base/home"
fermix="$home/.fermix"
mkdir -p "$home/.ssh" "$fermix/secrets" "$fermix/mobile" "$fermix/device" "$fermix/logs" \
  "$fermix/workspace" "$fermix/plugins/probe" "$fermix/plugins/run" "$base/run/fermix" \
  "$base/outside" "$base/scratch"
echo "private-key" > "$home/.ssh/id_probe"
echo "seeded = 1" > "$fermix/config.toml"
echo "token" > "$fermix/auth.json"
echo "token" > "$fermix/auth.json.tmp.1"
echo "secret-value" > "$fermix/secrets/KEY"
for key in gateway_key tls.key iroh_key; do echo "key" > "$fermix/mobile/$key"; done
echo "desktop-key" > "$fermix/device/desktop_key"
echo "log line" > "$fermix/logs/fermix.log"
echo "plugin-token" > "$fermix/plugins/run/token"
printf '#!/bin/sh\necho ran\n' > "$fermix/plugins/probe/tool"
chmod 755 "$fermix/plugins/probe/tool"
echo "enrollment" > "$base/run/fermix/enroll.code"
echo "b" > "$fermix/workspace/b.txt"
ln -s "$fermix/config.toml" "$base/outside/link"

# The real /run/fermix, where only root can make one.
targets=("$base")
if [ "$(id -u)" = 0 ] && [ -d /run ] && [ ! -e /run/fermix ]; then
  run_dir=/run/fermix
  mkdir -p "$run_dir"
  echo "enrollment" > "$run_dir/enroll.code"
  targets+=("$run_dir")
fi

# ── the rules ───────────────────────────────────────────────────────────────
shopt -s dotglob nullglob
declare -A carved=()
declare -A target=()
for t in "${targets[@]}"; do
  target["$t"]=1
  p="$t"
  while [ "$p" != "/" ]; do
    p="$(dirname "$p")"
    carved["$p"]=1
  done
done

rules=()
for dir in "${!carved[@]}"; do
  rules+=("l:$dir")
  prefix="$dir"
  [ "$dir" = "/" ] && prefix=""
  for child in "$prefix"/*; do
    [ -L "$child" ] && continue
    [ -n "${carved[$child]:-}" ] && continue
    [ -n "${target[$child]:-}" ] && continue
    rules+=("xrl:$child")
  done
done

# Inside the layout, as the builder carves `strict`: the home and the folders
# that hold a protected path are carved; the secrets, auth.json and its
# siblings, the identity bundle, device/, logs/, plugins/run/, ~/.ssh and
# run/fermix get no rule at all; plugins/ is readable but never runnable.
rules+=(
  "l:$base" "xrl:$base/outside" "xrl:$base/scratch"
  "l:$home"
  "l:$fermix" "xrl:$fermix/config.toml" "xrl:$fermix/workspace"
  "l:$fermix/plugins" "rl:$fermix/plugins/probe"
  "l:$base/run"
  "wc:$fermix/workspace" "wc:$base/scratch"
)
# The null sinks are written; the terminals also take ioctls, so a pty works.
for device in /dev/null /dev/zero /dev/full; do
  if [ -e "$device" ] && [ ! -L "$device" ]; then rules+=("w:$device"); fi
done
for device in /dev/tty /dev/ptmx /dev/pts; do
  if [ -e "$device" ] && [ ! -L "$device" ]; then rules+=("wi:$device"); fi
done
echo "rules: ${#rules[@]}"

# ── the cases ───────────────────────────────────────────────────────────────
failures=0
output=""
status=0

confined() {
  set +e
  output="$("$shim" "${rules[@]}" -- /bin/sh -c "$1" 2>&1)"
  status=$?
  set -e
}

pass() { printf 'ok    %s\n' "$1"; }
miss() { printf 'FAIL  %s (exit %s): %s\n' "$1" "$status" "$output"; failures=$((failures + 1)); }

# Refused by the kernel: the command ran and got EACCES, or EXDEV where a link
# or rename would give the file more access than it has where it is (Landlock's
# answer to reparenting), so the program says so.
denied() {
  local name="$1" command="$2"
  confined "$command"
  if [ "$status" -ne 0 ] &&
    printf '%s' "$output" | grep -q -e 'Permission denied' -e 'Invalid cross-device link'; then
    pass "denied: $name"
  else
    miss "should be denied: $name"
  fi
}

allowed() {
  local name="$1" command="$2"
  confined "$command"
  if [ "$status" -eq 0 ]; then pass "allowed: $name"; else miss "should be allowed: $name"; fi
}

# Refused by ABI 6's scoping, which the kernel answers with EPERM.
scoped_out() {
  local name="$1" command="$2"
  confined "$command"
  if [ "$status" -ne 0 ] && printf '%s' "$output" | grep -q 'Operation not permitted'; then
    pass "denied: $name"
  else
    miss "should be denied: $name"
  fi
}

# Waits up to 10 s for a condition (a command), looking every 0.1 s.
wait_for() {
  local tries=0
  until "$@"; do
    tries=$((tries + 1))
    [ "$tries" -lt 100 ] || return 1
    sleep 0.1
  done
}

# A process that exists and has not died (a zombie has).
alive() {
  local state
  state="$(cut -d' ' -f3 "/proc/$1/stat" 2>/dev/null)" || return 1
  [ -n "$state" ] && [ "$state" != Z ]
}
gone() { ! alive "$1"; }

# An abstract unix socket made outside the sandbox, for ABI 6's scope.
if [ "$abi" -ge 6 ]; then
  abstract="fermix-landlock-proof-$$"
  cat > "$work/listen.pl" <<'PERL'
use strict;
use Socket;
my ($name, $ready) = @ARGV;
socket(my $s, AF_UNIX, SOCK_STREAM, 0) or die "socket: $!\n";
bind($s, pack_sockaddr_un("\0$name")) or die "bind: $!\n";
listen($s, 1) or die "listen: $!\n";
open(my $f, '>', $ready) or die "ready: $!\n";
close($f);
sleep 300;
PERL
  cat > "$base/outside/connect.pl" <<'PERL'
use strict;
use Socket;
socket(my $s, AF_UNIX, SOCK_STREAM, 0) or die "socket: $!\n";
connect($s, pack_sockaddr_un("\0$ARGV[0]")) or die "connect: $!\n";
PERL
  perl "$work/listen.pl" "$abstract" "$work/listening" &
  listener=$!
  wait_for test -e "$work/listening" || { echo "error: the abstract socket never listened" >&2; exit 1; }
fi

denied "read a stored secret" "cat '$fermix/secrets/KEY'"
denied "read auth.json" "cat '$fermix/auth.json'"
denied "read a file named after auth.json" "cat '$fermix/auth.json.tmp.1'"
denied "read the gateway key" "cat '$fermix/mobile/gateway_key'"
denied "read the TLS private key" "cat '$fermix/mobile/tls.key'"
denied "read the iroh key" "cat '$fermix/mobile/iroh_key'"
denied "read the desktop key" "cat '$fermix/device/desktop_key'"
denied "read a log" "cat '$fermix/logs/fermix.log'"
denied "read a plugin's token" "cat '$fermix/plugins/run/token'"
denied "read the enrollment code" "cat '$base/run/fermix/enroll.code'"
denied "read an SSH key (strict)" "cat '$home/.ssh/id_probe'"
denied "read config.toml through a symlink in a readable folder, then write it" \
  "cat '$base/outside/link' >/dev/null && echo x >> '$base/outside/link'"
denied "write outside every grant" "echo x > '$base/outside/new'"
denied "append to config.toml" "echo x >> '$fermix/config.toml'"
denied "remove config.toml" "rm -f '$fermix/config.toml'"
denied "rename config.toml into the workspace" "mv '$fermix/config.toml' '$fermix/workspace/'"
denied "rename a workspace file out of every grant" \
  "echo a > '$fermix/workspace/a.txt' && mv '$fermix/workspace/a.txt' '$base/outside/'"
denied "hard-link a secret into the workspace" "ln '$fermix/secrets/KEY' '$fermix/workspace/k'"
denied "rename Fermix's home" "mv '$fermix' '$home/moved'"
denied "rename the workspace" "mv '$fermix/workspace' '$fermix/ws2'"
denied "make a folder in Fermix's home" "mkdir '$fermix/planted'"
denied "make a file directly in a carved folder" "touch '$home/planted'"
denied "run a plugin's program directly" "'$fermix/plugins/probe/tool'"
denied "read the environment of a process outside the sandbox" "cat /proc/\$PPID/environ"
denied "truncate config.toml" "truncate -s 0 '$fermix/config.toml'"
if [ "$abi" -ge 5 ]; then
  denied "an ioctl on a device that is not a terminal (ABI 5 and later)" "stty -F /dev/null"
else
  echo "limit device ioctls are not mediated before ABI 5 (Linux 6.10)"
fi
if [ "$abi" -ge 6 ]; then
  scoped_out "signal a process outside the sandbox (ABI 6 and later)" 'kill -0 "$PPID"'
  scoped_out "connect to an abstract unix socket made outside the sandbox (ABI 6 and later)" \
    "perl '$base/outside/connect.pl' '$abstract'"
else
  echo "limit signals and abstract unix sockets are not scoped before ABI 6 (Linux 6.12)"
fi
if [ -n "${run_dir:-}" ]; then
  denied "read the real /run/fermix/enroll.code" "cat /run/fermix/enroll.code"
  denied "write into the real /run/fermix" "echo x > /run/fermix/planted"
fi

allowed "write and read back in the workspace" \
  "echo a > '$fermix/workspace/c.txt' && grep -q a '$fermix/workspace/c.txt'"
allowed "rename across folders inside the workspace, then remove" \
  "mkdir '$fermix/workspace/d' && mv '$fermix/workspace/c.txt' '$fermix/workspace/d/' && rm -r '$fermix/workspace/d'"
allowed "rename from the workspace into the temp stand-in" \
  "mv '$fermix/workspace/b.txt' '$base/scratch/b.txt'"
allowed "mktemp in the temp stand-in" "TMPDIR='$base/scratch' mktemp >/dev/null"
allowed "read config.toml" "grep -q seeded '$fermix/config.toml'"
allowed "list a read-denied folder's names (a stated limit)" "ls '$fermix/secrets' | grep -q KEY"
allowed "write /dev/null" "echo x > /dev/null"
allowed "run programs from the system" "/bin/ls /usr/bin >/dev/null"
allowed "run a plugin's script through an interpreter" "sh '$fermix/plugins/probe/tool' | grep -q ran"
allowed "no_new_privs is set" "grep -q '^NoNewPrivs:[[:space:]]*1' /proc/self/status"
allowed "allocate and use a pseudo-terminal" "script -qec true /dev/null"
allowed "signal a process the command started" 'sleep 30 & kill "$!"'
allowed "the command leads a session and process group of its own, with no terminal" \
  'set -- $(cut -d" " -f5-7 /proc/$$/stat); [ "$1" = "$$" ] && [ "$2" = "$$" ] && [ "$3" = 0 ]'

[ ! -e "$base/outside/new" ] || miss "a file appeared outside every grant"
grep -q '^seeded = 1$' "$fermix/config.toml" || miss "config.toml changed"
[ -d "$fermix" ] || miss "Fermix's home moved"
[ ! -e "$fermix/workspace/k" ] || miss "a secret was linked into the workspace"

# ── the session ─────────────────────────────────────────────────────────────
# Under script(1) the shell that starts the shim has a controlling terminal,
# as a `fermix` started by hand does; the command it runs must have none, or
# it could push input into that terminal (TIOCSTI).
tty_probe="$work/tty_probe.sh"
{
  printf 'caller="$(cut -d" " -f7 /proc/$$/stat)"\n'
  printf 'rules=(\n'
  printf '  %q\n' "${rules[@]}"
  printf ')\n'
  printf '%q "${rules[@]}" -- /bin/sh -c %q\n' "$shim" \
    'echo "command-tty=$(cut -d" " -f7 /proc/$$/stat)"'
  printf 'echo "caller-tty=$caller"\n'
} > "$tty_probe"
set +e
output="$(script -qec "bash '$tty_probe'" /dev/null 2>&1 | tr -d '\r')"
status=$?
set -e
name="the command does not keep its caller's terminal"
if printf '%s' "$output" | grep -q '^caller-tty=0$'; then
  miss "$name (the caller had no terminal, so this proves nothing)"
elif printf '%s' "$output" | grep -q '^command-tty=0$'; then
  pass "$name"
else
  miss "$name"
fi

# The daemon ends a command by signalling the process group whose id is the
# command's pid (kill_pgid/2), which must reach what the command started:
# whether the shim started its session or already led one, as a port of the
# Erlang VM does (`setsid` stands in for it here).
group_signal_case() {
  local name="$1"
  shift
  local pidfile="$base/scratch/started.pid"
  rm -f "$pidfile"
  "$@" "$shim" "${rules[@]}" -- /bin/sh -c 'sleep 300 & echo "$!" > "$1"; wait' sh "$pidfile" &
  local leader=$!
  if ! wait_for test -s "$pidfile"; then
    kill -KILL "$leader" 2>/dev/null || true
    status="none" output="the command never wrote its child's pid"
    miss "$name"
    return
  fi
  local started
  started="$(cat "$pidfile")"
  kill -KILL -- "-$leader" 2>/dev/null || true
  if wait_for gone "$started"; then
    pass "$name"
  else
    status="alive" output="pid $started outlived the group signal"
    miss "$name"
  fi
  # Whatever the group signal missed is ended one by one, so a miss never
  # leaves the proof waiting on it.
  kill -KILL "$leader" "$started" 2>/dev/null || true
  wait "$leader" 2>/dev/null || true
}
group_signal_case "a signal to the command's process group reaches what it started"
group_signal_case "the same when the shim already leads its session" setsid -w

# ── the shim's own refusals ─────────────────────────────────────────────────
shim_case() {
  local name="$1" expected="$2" needle="$3"
  shift 3
  set +e
  output="$("$@" 2>&1)"
  status=$?
  set -e
  if [ "$status" -eq "$expected" ] && { [ -z "$needle" ] || printf '%s' "$output" | grep -q -- "$needle"; }; then
    pass "shim: $name"
  else
    miss "shim: $name (expected exit $expected and \"$needle\")"
  fi
}

marker="$base/scratch/ran"
shim_case "ABI 2 refuses before anything runs" 69 "below 3 (Linux before 6.2)" \
  "$shim_abi2" "wc:$base/scratch" -- /bin/sh -c "touch '$marker'"
[ ! -e "$marker" ] || miss "the command ran on a refused ABI"
shim_case "--abi on ABI 2" 69 "Landlock ABI 2 is below 3" "$shim_abi2" --abi
# A build that reports ABI 4 on a newer kernel: it holds commands, and asks
# the kernel for neither ABI 5's device ioctls nor ABI 6's scopes.
shim_case "ABI 4 holds commands" 0 "" \
  "$shim_abi4" "${rules[@]}" -- /bin/sh -c "cat '$fermix/config.toml' >/dev/null"
if [ "$abi" -ge 5 ]; then
  shim_case "ABI 4 leaves device ioctls as they are" 1 "Inappropriate ioctl" \
    "$shim_abi4" "${rules[@]}" -- /bin/sh -c 'stty -F /dev/null'
fi
if [ "$abi" -ge 6 ]; then
  shim_case "ABI 4 leaves signals as they are" 0 "" \
    "$shim_abi4" "${rules[@]}" -- /bin/sh -c 'kill -0 "$PPID"'
fi
shim_case "a shim that already leads its own session goes on" 0 "" \
  setsid -w "$shim" "${rules[@]}" -- /bin/sh -c 'set -- $(cut -d" " -f6 /proc/$$/stat); [ "$1" = "$$" ]'
session_marker="$base/scratch/ran-in-callers-session"
shim_case "a process-group leader in its caller's session is refused" 71 \
  "cannot start a session of its own" \
  perl -e 'setpgrp(0, 0) or die "setpgrp: $!\n"; exec { $ARGV[0] } @ARGV or die "exec: $!\n"' \
  "$shim" "${rules[@]}" -- /bin/sh -c "touch '$session_marker'"
[ ! -e "$session_marker" ] || miss "the command ran in its caller's session"
shim_case "a rule naming a symlink" 65 "is a symlink" \
  "$shim" "r:$base/outside/link" -- /bin/true
shim_case "a malformed rule" 64 "malformed rule" "$shim" "q:/tmp" -- /bin/true
shim_case "a relative rule" 64 "malformed rule" "$shim" "r:tmp" -- /bin/true
shim_case "no separator" 64 "usage" "$shim" "r:/usr"
shim_case "a missing executable" 127 "cannot run" "$shim" "${rules[@]}" -- /nonexistent/prog
shim_case "a vanished rule path grants nothing and is skipped" 0 "" \
  "$shim" "${rules[@]}" "r:$base/vanished" -- /bin/true

echo
if [ "$failures" -ne 0 ]; then
  echo "$failures case(s) did not hold"
  exit 1
fi
echo "every case held"
