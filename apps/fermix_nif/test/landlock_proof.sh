#!/usr/bin/env bash
# Prove the fermix_landlock shim against the running Linux kernel
# (OS_SANDBOX_ENFORCEMENT stage B, M75 D15).
#
# Usage: apps/fermix_nif/test/landlock_proof.sh [SHIM]
#
# SHIM is a built fermix_landlock. Without it the script builds one from
# c_src/fermix_landlock.c with cc under the release's strict flags, plus a
# test build that reports ABI 1, which proves the refusal of a kernel before
# 5.19 on any kernel.
#
# It lays out a Fermix home in a scratch folder and carves rules the way
# `FermixCore.Sandbox.Landlock` does for `strict`: every folder above a
# protected path gets only `l`, its other entries are granted whole, and the
# workspace and a temp stand-in are writable. Then it runs each case under the
# shim and checks the kernel's answer. Running as root (a container), it also
# proves the real /run/fermix. Exits 1 when any case does not hold, and on a
# host without Landlock ABI 2: this is the gate that says so.
set -euo pipefail

nif_dir="$(cd "$(dirname "$0")/.." && pwd -P)"
work="$(mktemp -d "${TMPDIR:-/tmp}/fermix-landlock-proof.XXXXXX")"
work="$(cd "$work" && pwd -P)"
case "$work" in
  */fermix-landlock-proof.*) ;;
  *) echo "error: unexpected scratch folder $work" >&2; exit 1 ;;
esac
cleanup() {
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
shim_abi1="$work/fermix_landlock_abi1"
cc "${flags[@]}" -DFERMIX_LANDLOCK_TEST_ABI=1 "$nif_dir/c_src/fermix_landlock.c" -o "$shim_abi1"

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
for device in /dev/null /dev/zero /dev/full /dev/tty /dev/ptmx /dev/pts; do
  if [ -e "$device" ] && [ ! -L "$device" ]; then rules+=("w:$device"); fi
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
if [ "$abi" -ge 3 ]; then
  denied "truncate config.toml (ABI 3 and later)" "truncate -s 0 '$fermix/config.toml'"
else
  echo "limit truncate(2) is not mediated before ABI 3 (Linux 6.2)"
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
if command -v script >/dev/null 2>&1; then
  allowed "allocate and use a pseudo-terminal" "script -qec true /dev/null"
fi

[ ! -e "$base/outside/new" ] || miss "a file appeared outside every grant"
grep -q '^seeded = 1$' "$fermix/config.toml" || miss "config.toml changed"
[ -d "$fermix" ] || miss "Fermix's home moved"
[ ! -e "$fermix/workspace/k" ] || miss "a secret was linked into the workspace"

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
shim_case "ABI 1 refuses before anything runs" 69 "below 2 (Linux before 5.19)" \
  "$shim_abi1" "wc:$base/scratch" -- /bin/sh -c "touch '$marker'"
[ ! -e "$marker" ] || miss "the command ran on a refused ABI"
shim_case "--abi on ABI 1" 69 "Landlock ABI 1 is below 2" "$shim_abi1" --abi
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
