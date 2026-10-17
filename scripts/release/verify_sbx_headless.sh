#!/usr/bin/env bash
# The single-quoted commands run in the sandbox, so $HOME there is the agent's.
# shellcheck disable=SC2016
# Prove a Fermix kit image in a fresh Docker cloud sandbox (M64): the boot hook
# sets Fermix up headless, the daemon comes up, the provider key the cloud
# injects works for one real turn, and the file store holds the settings.
#
#   scripts/release/verify_sbx_headless.sh docker.io/sbx/fermix:0.16.0
#
# Needs `sbx login` and `sbx --cloud secret set anthropic` on this machine. The
# sandbox is the smallest size with a one-hour TTL that deletes it, and this
# script removes it on every exit, so a failed run costs cents at most.

set -euo pipefail

usage() {
  echo "usage: verify_sbx_headless.sh <kit image reference>" >&2
  exit 2
}

fail() {
  echo "verify_sbx_headless.sh: FAIL: $*" >&2
  exit 1
}

[ "$#" -eq 1 ] || usage
image="$1"
case "$image" in
  -* | "") usage ;;
esac

readonly boot_wait_polls=36 # 36 polls 5 seconds apart: 3 minutes
readonly poll_seconds=5
name="fermix-verify-$(date +%s)"
readonly name

remove_sandbox() {
  sbx --cloud rm --force "$name" >/dev/null 2>&1 ||
    echo "verify_sbx_headless.sh: could not remove $name; its one-hour TTL deletes it" >&2
}

in_sandbox() {
  sbx --cloud exec "$name" bash -lc "$1"
}

step() {
  echo "==> $*"
}

step "Creating $name from $image"
trap remove_sandbox EXIT
sbx --cloud run -d --name "$name" --cpus 1 --memory 2g --ttl 1h --on-timeout delete "$image" ||
  fail "sbx --cloud run could not create a sandbox from $image"

step "Waiting for the daemon the boot hook starts to answer"
# The control socket opens before the rest of the daemon, so wait for an
# answer, not for the socket.
polls=0
until in_sandbox 'fermix status' >/dev/null 2>&1; do
  polls=$((polls + 1))
  if ((polls >= boot_wait_polls)); then
    in_sandbox 'tail -n 40 "$HOME/.fermix-sandbox-boot.log"' >&2 || true
    fail "Fermix did not answer within $((boot_wait_polls * poll_seconds)) seconds; the boot log is above"
  fi
  sleep "$poll_seconds"
done

step "Checking status, the first-boot marker and the secret store"
in_sandbox 'fermix status' || fail "fermix status failed"
in_sandbox 'test -e "$HOME/.fermix-sandbox-setup-done"' || fail "the boot hook never marked setup done"
store="$(in_sandbox "fermix settings show secrets --json | python3 -c 'import json, sys; \
print(next(r[\"value\"] for r in json.load(sys.stdin)[\"rows\"] if r[\"key\"] == \"secret_store\"))'" 2>&1)" ||
  fail "could not read the secret_store row: $store"
[ "$store" = file ] || fail "the sandbox must use the file secret store, not: $store"

step "Asking one question through the injected provider key"
# Only stdout is the reply; what Fermix says on stderr goes straight to ours.
reply="$(in_sandbox 'fermix ask "Say hello in one short sentence."')" ||
  fail "fermix ask failed; what it said is above"
[ -n "${reply//[[:space:]]/}" ] || fail "fermix ask exited 0 with an empty reply"
echo "$reply"

step "PASS: $image runs Fermix headless in a Docker cloud sandbox"
