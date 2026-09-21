#!/usr/bin/env bash
# Build the `fermix` deb, rpm and app-engine archive for one Linux target
# (M38 §2.2, §12.1; single-package amendment §5.1).
#
# One compile produces all three: the engine tree is staged once and the
# packages and the archive are both made from it, so the engine layout in the
# headless package and in the desktop package cannot differ.
#
# The release build snapshots the exact commit and refuses a dirty checkout,
# the way the app-engine build does. `--dev` builds the working tree instead
# and stamps a build id that says so, for a local package nobody will publish.
# `--container` runs this same script inside the pinned build image, which is
# how an arm64 package is produced on a development machine.

set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: build_linux_packages.sh <linux_x86_64|linux_aarch64> <version> <output-dir> [--container] [--dev]

  Writes fermix_<version>_<arch>.deb, fermix-<version>-1.<arch>.rpm and
  fermix_app_engine_<target>.tar.gz into <output-dir>.

  --container  build inside packaging/linux/docker/Dockerfile.build
  --dev        build the working tree, stamped dev-<short-sha>-dirty-<diff-sha>
USAGE
  exit 2
}

fail() {
  echo "build_linux_packages.sh: $1" >&2
  exit 1
}

# What a `--dev` build id must move with. The commit alone cannot tell two
# dirty builds apart, and the manifest's build id is what a bug report quotes:
# without this, an engine carrying a fix and the engine that lacks it claim the
# same identity. The tracked diff plus the content of every untracked,
# non-ignored file is the whole of what a snapshot build differs by.
dirty_digest() {
  local digest
  # In the repository, because `ls-files` names its files relative to it.
  digest="$(
    cd "$repo_root" &&
      {
        git diff HEAD
        git ls-files --others --exclude-standard -z | xargs -0 -r sha256sum
      } | sha256sum | cut -c1-8
  )" || fail "cannot digest the working tree's difference from HEAD"
  [ -n "$digest" ] || fail "the working tree's difference digested to nothing"
  printf '%s' "$digest"
}

image="fermix-linux-package-build"
container=0
dev=0
positional=()

for argument in "$@"; do
  case "$argument" in
    --container) container=1 ;;
    --dev) dev=1 ;;
    -*) usage ;;
    *) positional+=("$argument") ;;
  esac
done

[ "${#positional[@]}" -eq 3 ] || usage

target="${positional[0]}"
version="${positional[1]}"
output_arg="${positional[2]}"

case "$target" in
  linux_x86_64 | linux_aarch64) ;;
  *) fail "unsupported target: $target" ;;
esac

# Neither package may carry a Debian revision or an rpm epoch, so a version
# either family would read differently is refused before anything is built.
case "$version" in
  *-* | *:*) fail "version $version carries a revision or an epoch, and neither package may" ;;
esac
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  fail "version must be a plain MAJOR.MINOR.PATCH version without a leading v"

repo_root="$(cd "$(dirname "$0")/../.." && pwd -P)"
mkdir -p "$output_arg"
output_dir="$(cd "$output_arg" && pwd -P)"

if [ "$container" -eq 1 ]; then
  command -v docker >/dev/null 2>&1 || fail "docker is required by --container"

  case "$output_dir" in
    "$repo_root"/*) relative_output="${output_dir#"$repo_root"/}" ;;
    *) fail "--container writes inside the checkout; pass an output directory under $repo_root" ;;
  esac

  case "$target" in
    linux_x86_64) platform="linux/amd64" ;;
    linux_aarch64) platform="linux/arm64" ;;
  esac

  docker build --platform "$platform" -t "$image" \
    -f "$repo_root/packaging/linux/docker/Dockerfile.build" \
    "$repo_root/packaging/linux/docker"

  cache="$repo_root/packaging/linux/out/container-cache"
  container_home="$repo_root/packaging/linux/out/container-home"
  # The build's scratch tree is a whole source snapshot with its own `deps`
  # and `_build`, several gigabytes of it. Left in the container's writable
  # layer it fills the Docker data root, which is usually a far smaller device
  # than the checkout's, so it goes on the bind mount beside the cache and the
  # home for the same reason they do.
  container_tmp="$repo_root/packaging/linux/out/container-tmp"
  mkdir -p "$cache" "$container_home" "$container_tmp"

  inner=("scripts/release/build_linux_packages.sh" "$target" "$version" "/work/$relative_output")
  [ "$dev" -eq 0 ] || inner+=("--dev")

  exec docker run --rm \
    --platform "$platform" \
    -v "$repo_root:/work" \
    -w /work \
    -u "$(id -u):$(id -g)" \
    -v "$container_home:/home/build" \
    -e HOME=/home/build \
    -e GIT_CONFIG_COUNT=1 \
    -e GIT_CONFIG_KEY_0=safe.directory \
    -e GIT_CONFIG_VALUE_0=/work \
    -e XDG_CACHE_HOME=/work/packaging/linux/out/container-cache \
    -e HEX_HOME=/work/packaging/linux/out/container-cache/hex \
    -e TMPDIR=/work/packaging/linux/out/container-tmp \
    -e "FERMIX_BUILD_ID=${FERMIX_BUILD_ID:-}" \
    -e "FERMIX_BUILD_SOURCE_COMMIT=${FERMIX_BUILD_SOURCE_COMMIT:-}" \
    "$image" \
    "${inner[@]}"
fi

[ "$(uname -s)" = "Linux" ] ||
  fail "a Linux package is built on Linux; re-run with --container"

# One snapshot rule, two sources for it: a release builds the exact commit out
# of git, a --dev build copies the working tree. Neither builds in place, so a
# host's `_build` and `deps` — a macOS developer's, in the container case —
# can never leak into a Linux package.
if [ "$dev" -eq 1 ]; then
  short_sha="$(cd "$repo_root" && git rev-parse --short=12 HEAD)" ||
    fail "cannot resolve the working tree's commit"
  FERMIX_BUILD_ID="dev-${short_sha}-dirty-$(dirty_digest)"
  FERMIX_BUILD_SOURCE_COMMIT="$(cd "$repo_root" && git rev-parse HEAD)"
  export FERMIX_BUILD_ID FERMIX_BUILD_SOURCE_COMMIT
else
  : "${FERMIX_BUILD_ID:?FERMIX_BUILD_ID is required}"
  : "${FERMIX_BUILD_SOURCE_COMMIT:?FERMIX_BUILD_SOURCE_COMMIT is required}"

  [[ "$FERMIX_BUILD_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$ ]] ||
    fail "FERMIX_BUILD_ID has an invalid format"
  [[ "$FERMIX_BUILD_SOURCE_COMMIT" =~ ^[0-9a-fA-F]{40}$ ]] ||
    fail "FERMIX_BUILD_SOURCE_COMMIT must be a full 40-character commit"

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
  [ -z "$checkout_status" ] ||
    fail "checkout has uncommitted source changes:
$checkout_status"
fi

scratch_parent="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
mkdir -p "$scratch_parent"
scratch_parent="$(cd "$scratch_parent" && pwd -P)"
build_root="$(mktemp -d "$scratch_parent/fermix-linux-package-${target}.XXXXXX")"

cleanup() {
  case "$build_root" in
    "$scratch_parent"/fermix-linux-package-"$target".*) rm -rf -- "$build_root" ;;
    *) echo "build_linux_packages.sh: refusing unsafe cleanup path" >&2; return 1 ;;
  esac
}
trap cleanup EXIT

source_root="$build_root/source"
mkdir -p "$source_root"

if [ "$dev" -eq 1 ]; then
  # The working tree exactly as git sees it: every tracked file at its current
  # content plus every untracked file that is not ignored. Ignored trees —
  # `_build`, `deps`, a developer's worktrees — are what must not travel.
  if ! (cd "$repo_root" && git ls-files -z --cached --others --exclude-standard) |
    tar -C "$repo_root" -cf - --null --no-recursion -T - |
    tar -xf - -C "$source_root"; then
    fail "cannot copy the working tree"
  fi
elif ! (cd "$repo_root" && git archive --format=tar "$checkout_commit") |
  tar -xf - -C "$source_root"; then
  fail "cannot create the exact source snapshot"
fi

unset MIX_BUILD_PATH MIX_DEPS_PATH
export MIX_ENV=prod
export FERMIX_BUILD_DISTRIBUTION=linux_package
export FERMIX_BUILD_TARGET="$target"
export BURRITO_TARGET="$target"

cd "$source_root"
mix deps.get
mix compile --warnings-as-errors
(
  cd "$source_root/apps/fermix_web"
  mix assets.setup
  mix assets.deploy
)
mix release fermix_linux_package --overwrite

# The app-engine manifest states the same protocol windows the macOS manifest
# states, so they are read out of the engine that was just compiled rather than
# restated in a packaging script that would drift away from the wire.
protocols="$build_root/protocols.json"
FERMIX_PROTOCOLS_OUT="$protocols" mix run --no-start -e \
  'File.write!(System.fetch_env!("FERMIX_PROTOCOLS_OUT"), Jason.encode!(FermixCore.BuildInfo.protocols()))'
[ -s "$protocols" ] || fail "the compiled engine reported no protocol windows"

python3 "$source_root/scripts/release/linux_packages.py" \
  --target "$target" \
  --version "$version" \
  --output-dir "$output_dir" \
  --source-root "$source_root" \
  --build-id "$FERMIX_BUILD_ID" \
  --source-commit "$FERMIX_BUILD_SOURCE_COMMIT" \
  --protocols "$protocols" \
  --app-engine-dir "$output_dir"
