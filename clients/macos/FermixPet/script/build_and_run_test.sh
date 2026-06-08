#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/script/build_and_run.sh"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/home" "$TMP_DIR/install"

cat >"$TMP_DIR/bin/swift" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

echo "$*" >>"$FAKE_SWIFT_LOG"

BUILD_PATH=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-path)
      BUILD_PATH="$2"
      shift 2
      ;;
    --show-bin-path)
      echo "$BUILD_PATH/arm64-apple-macosx/debug"
      exit 0
      ;;
    *)
      shift
      ;;
  esac
done

if [[ -z "$BUILD_PATH" ]]; then
  echo "missing --build-path" >&2
  exit 1
fi

BUILD_DIR="$BUILD_PATH/arm64-apple-macosx/debug"
RESOURCE_DIR="$BUILD_DIR/FermixPet_FermixPet.bundle"
mkdir -p "$RESOURCE_DIR"
printf '#!/usr/bin/env bash\n' >"$BUILD_DIR/FermixPet"
chmod +x "$BUILD_DIR/FermixPet"
printf 'icon\n' >"$RESOURCE_DIR/FermixPet.icns"
SH

cat >"$TMP_DIR/bin/pgrep" <<'SH'
#!/usr/bin/env bash
exit 1
SH

chmod +x "$TMP_DIR/bin/swift" "$TMP_DIR/bin/pgrep"

export FAKE_SWIFT_LOG="$TMP_DIR/swift.log"
export FERMIXPET_INSTALL_DIR="$TMP_DIR/install"

HOME="$TMP_DIR/home" \
PATH="$TMP_DIR/bin:$PATH" \
  "$SCRIPT" install

EXPECTED_BUILD_PATH="$TMP_DIR/home/Library/Caches/io.tezra.FermixPet/swiftpm-build"
INSTALLED_APP="$TMP_DIR/install/FermixPet.app"

test -x "$INSTALLED_APP/Contents/MacOS/FermixPet"
test -f "$INSTALLED_APP/Contents/Info.plist"
grep -F -- "--build-path $EXPECTED_BUILD_PATH" "$FAKE_SWIFT_LOG" >/dev/null
grep -F -- "-c release" "$FAKE_SWIFT_LOG" >/dev/null

echo "build_and_run_test: ok"
