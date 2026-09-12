#!/usr/bin/env bash
# Verify one standalone release artifact and its packaged macOS spawn shim.

set -euo pipefail

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

usage() {
  printf 'usage: %s <artifact> <target> <version>\n' "$0" >&2
  exit 2
}

[ "$#" -eq 3 ] || usage

artifact="$1"
target="$2"
version="$3"

case "$target" in
  linux_x86_64|linux_aarch64|macos_aarch64|macos_x86_64) ;;
  *) fail "unsupported standalone target: $target" ;;
esac

[ -n "$version" ] || fail "expected version must not be empty"
[ ! -L "$artifact" ] && [ -f "$artifact" ] || fail "standalone artifact must be a regular file, not a symlink: $artifact"

runtime_parent="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
[ -d "$runtime_parent" ] || fail "standalone verification temporary directory does not exist"
runtime_root="$(mktemp -d "$runtime_parent/fermix-standalone-verify.XXXXXX")"
home="$runtime_root/home"
fermix_home="$runtime_root/fermix-home"
mkdir -m 700 "$home" "$fermix_home"

cleanup() {
  rm -rf -- "$runtime_root"
}
trap cleanup EXIT

chmod +x "$artifact"
if ! version_output="$(HOME="$home" FERMIX_HOME="$fermix_home" "$artifact" --version 2>&1)"; then
  printf '%s\n' "$version_output" >&2
  fail "standalone --version command failed"
fi
printf '%s\n' "$version_output"
case "$version_output" in
  *"$version"*) ;;
  *) fail "--version output does not contain $version" ;;
esac

case "$target" in
  macos_aarch64|macos_x86_64) ;;
  *) exit 0 ;;
esac

disclaim=""
while IFS= read -r -d '' candidate; do
  disclaim="$candidate"
  break
done < <(find "$home" -type f -path '*/fermix_nif/priv/disclaim' -print0)

[ -n "$disclaim" ] || fail "packaged disclaim shim not found in the isolated smoke home"
[ -x "$disclaim" ] || fail "packaged disclaim shim is not executable"

if ! check_output="$("$disclaim" --check 2>&1)"; then
  printf '%s\n' "$check_output" >&2
  fail "packaged disclaim shim self-check failed"
fi
printf '%s\n' "$check_output"
