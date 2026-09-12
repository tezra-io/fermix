#!/usr/bin/env bash
# Build and package one native macOS app-engine release in a fresh compile path.

set -euo pipefail

usage() {
  echo "usage: build_app_engine.sh <macos_aarch64|macos_x86_64> <output-dir> <version>" >&2
  exit 2
}

fail() {
  echo "build_app_engine.sh: $1" >&2
  exit 1
}

[ "$#" -eq 3 ] || usage

target="$1"
output_arg="$2"
version="$3"

case "$target" in
  macos_aarch64) expected_arch="arm64" ;;
  macos_x86_64) expected_arch="x86_64" ;;
  *) fail "unsupported target: $target" ;;
esac

[ "$(uname -s)" = "Darwin" ] || fail "$target must be built natively on macOS"

machine="$(uname -m)"
case "$machine" in
  arm64|aarch64) host_arch="arm64" ;;
  x86_64|amd64) host_arch="x86_64" ;;
  *) fail "unsupported host architecture: $machine" ;;
esac

[ "$host_arch" = "$expected_arch" ] ||
  fail "$target requires host architecture $expected_arch, found $host_arch"

: "${FERMIX_BUILD_ID:?FERMIX_BUILD_ID is required}"
: "${FERMIX_BUILD_SOURCE_COMMIT:?FERMIX_BUILD_SOURCE_COMMIT is required}"

[[ "$FERMIX_BUILD_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$ ]] ||
  fail "FERMIX_BUILD_ID has an invalid format"
[[ "$FERMIX_BUILD_SOURCE_COMMIT" =~ ^[0-9a-fA-F]{40}$ ]] ||
  fail "FERMIX_BUILD_SOURCE_COMMIT must be a full 40-character commit"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]] ||
  fail "version must be a semantic version without a leading v"

repo_root="$(cd "$(dirname "$0")/../.." && pwd -P)"
if ! checkout_commit="$(cd "$repo_root" && git rev-parse HEAD)"; then
  fail "cannot resolve the checkout source commit"
fi
checkout_commit="$(printf '%s' "$checkout_commit" | tr '[:upper:]' '[:lower:]')"
requested_commit="$(printf '%s' "$FERMIX_BUILD_SOURCE_COMMIT" | tr '[:upper:]' '[:lower:]')"
[ "$checkout_commit" = "$requested_commit" ] ||
  fail "FERMIX_BUILD_SOURCE_COMMIT does not match the checkout"
if ! checkout_status="$(cd "$repo_root" && git status --porcelain --untracked-files=all)"; then
  fail "cannot inspect the checkout source state"
fi
[ -z "$checkout_status" ] || fail "checkout has uncommitted source changes"

mkdir -p "$output_arg"
output_dir="$(cd "$output_arg" && pwd -P)"
destination="$output_dir/fermix_app_engine_${target}.tar.gz"
[ ! -e "$destination" ] && [ ! -L "$destination" ] ||
  fail "archive already exists: $(basename "$destination")"

scratch_parent="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
mkdir -p "$scratch_parent"
scratch_parent="$(cd "$scratch_parent" && pwd -P)"
build_root="$(mktemp -d "$scratch_parent/fermix-app-engine-${target}.XXXXXX")"

cleanup() {
  case "$build_root" in
    "$scratch_parent"/fermix-app-engine-"$target".*) rm -rf -- "$build_root" ;;
    *) echo "build_app_engine.sh: refusing unsafe cleanup path" >&2; return 1 ;;
  esac
}
trap cleanup EXIT

source_root="$build_root/source"
mkdir -p "$source_root"
if ! (cd "$repo_root" && git archive --format=tar "$checkout_commit") |
  tar -xf - -C "$source_root"; then
  fail "cannot create the exact source snapshot"
fi

unset MIX_BUILD_PATH MIX_DEPS_PATH
export MIX_ENV=prod
export FERMIX_BUILD_DISTRIBUTION=macos_app
export FERMIX_BUILD_TARGET="$target"
release_root="$build_root/release"

cd "$source_root"
mix deps.get
mix deps.compile
mix compile --warnings-as-errors
(
  cd "$source_root/apps/fermix_web"
  mix assets.setup
  mix assets.deploy
)
mix release fermix_app_engine --path "$release_root"

python3 scripts/release/package_app_engine.py \
  --release-root "$release_root" \
  --target "$target" \
  --output-dir "$output_dir" \
  --version "$version" \
  --source-commit "$FERMIX_BUILD_SOURCE_COMMIT"
