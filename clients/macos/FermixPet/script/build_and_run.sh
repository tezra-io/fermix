#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="FermixPet"
BUNDLE_ID="io.tezra.FermixPet"
MIN_SYSTEM_VERSION="13.0"
RESOURCE_BUNDLE_NAME="FermixPet_FermixPet.bundle"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOME_DIR="${HOME:-}"
CACHE_ROOT="${FERMIXPET_CACHE_DIR:-$HOME_DIR/Library/Caches/io.tezra.FermixPet}"
SWIFTPM_BUILD_PATH="${FERMIXPET_SWIFTPM_BUILD_PATH:-$CACHE_ROOT/swiftpm-build}"
STAGING_DIR="${FERMIXPET_STAGE_DIR:-$CACHE_ROOT/app}"
INSTALL_DIR="${FERMIXPET_INSTALL_DIR:-$HOME_DIR/Applications}"
BUILD_CONFIGURATION="${FERMIXPET_SWIFT_CONFIGURATION:-debug}"
SIGN_IDENTITY="${FERMIXPET_SIGN_IDENTITY:-FermixPet Dev}"

case "$MODE" in
  install|--install)
    BUILD_CONFIGURATION="${FERMIXPET_SWIFT_CONFIGURATION:-release}"
    ;;
esac

APP_BUNDLE="$STAGING_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
INSTALLED_APP="$INSTALL_DIR/$APP_NAME.app"

fail() {
  echo "error: $*" >&2
  exit 1
}

validate_paths() {
  [[ -n "$HOME_DIR" ]] || fail "HOME is not set"
  [[ -n "$CACHE_ROOT" ]] || fail "FERMIXPET_CACHE_DIR must not be empty"
  [[ -n "$SWIFTPM_BUILD_PATH" ]] || fail "FERMIXPET_SWIFTPM_BUILD_PATH must not be empty"
  [[ -n "$STAGING_DIR" ]] || fail "FERMIXPET_STAGE_DIR must not be empty"
  [[ -n "$INSTALL_DIR" ]] || fail "FERMIXPET_INSTALL_DIR must not be empty"
  [[ "$BUILD_CONFIGURATION" == "debug" || "$BUILD_CONFIGURATION" == "release" ]] ||
    fail "FERMIXPET_SWIFT_CONFIGURATION must be debug or release"
}

stop_running_app() {
  if pgrep -x "$APP_NAME" >/dev/null; then
    pkill -x "$APP_NAME"
  fi
}

write_info_plist() {
  cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>FermixPet</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>FermixPet uses microphone input only while you explicitly start a voice call.</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST
}

ensure_signing_identity() {
  # `-v` lists valid (trusted) identities only; a self-signed cert is untrusted,
  # so match on the codesigning policy without `-v`.
  if security find-identity -p codesigning | grep -qF "$SIGN_IDENTITY"; then
    return 0
  fi

  echo "Creating self-signed code-signing identity \"$SIGN_IDENTITY\" (one-time)..."
  local dir cnf kc
  dir="$(mktemp -d)"
  cnf="$dir/cert.cnf"
  kc="$HOME_DIR/Library/Keychains/login.keychain-db"

  cat >"$cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $SIGN_IDENTITY
[v3]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF

  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$dir/key.pem" \
    -out "$dir/cert.pem" -days 3650 -config "$cnf" >/dev/null 2>&1 ||
    { rm -rf "$dir"; fail "failed to generate self-signed certificate"; }
  openssl pkcs12 -export -inkey "$dir/key.pem" -in "$dir/cert.pem" \
    -name "$SIGN_IDENTITY" -out "$dir/identity.p12" -passout pass:fermixpet >/dev/null 2>&1 ||
    { rm -rf "$dir"; fail "failed to package certificate"; }
  security import "$dir/identity.p12" -k "$kc" -P fermixpet -T /usr/bin/codesign >/dev/null 2>&1 ||
    { rm -rf "$dir"; fail "failed to import certificate into login keychain"; }
  rm -rf "$dir"

  security find-identity -p codesigning | grep -qF "$SIGN_IDENTITY" ||
    fail "certificate import did not register identity \"$SIGN_IDENTITY\""
  echo "Created \"$SIGN_IDENTITY\". macOS will ask for your login password the first"
  echo "time codesign uses it - enter it and click \"Always Allow\" (asked once)."
}

sign_app_bundle() {
  # macOS TCC keys the microphone grant to the app's designated requirement,
  # which derives from the code signature. An ad-hoc signature has no stable
  # requirement (only a cdhash that changes on every `swift build`), so a stored
  # mic grant stops matching after the next rebuild and the OS silently denies
  # capture. Signing with a stable self-signed identity gives a constant
  # requirement across rebuilds, so the grant survives.
  ensure_signing_identity

  codesign --force \
    --sign "$SIGN_IDENTITY" \
    --identifier "$BUNDLE_ID" \
    "$APP_BUNDLE"
}

stage_app_bundle() {
  local build_binary="$1"
  local build_resource_bundle="$2"

  rm -rf "$APP_BUNDLE"
  mkdir -p "$APP_MACOS" "$APP_RESOURCES"
  cp "$build_binary" "$APP_BINARY"
  cp "$build_resource_bundle/FermixPet.icns" "$APP_RESOURCES/FermixPet.icns"
  cp -R "$build_resource_bundle" "$APP_RESOURCES/$RESOURCE_BUNDLE_NAME"
  chmod +x "$APP_BINARY"
  write_info_plist
  sign_app_bundle
}

build_app_bundle() {
  cd "$ROOT_DIR"
  mkdir -p "$SWIFTPM_BUILD_PATH" "$STAGING_DIR"
  swift build --build-path "$SWIFTPM_BUILD_PATH" -c "$BUILD_CONFIGURATION"

  local build_dir
  build_dir="$(swift build --build-path "$SWIFTPM_BUILD_PATH" -c "$BUILD_CONFIGURATION" --show-bin-path)"

  local build_binary="$build_dir/$APP_NAME"
  local build_resource_bundle="$build_dir/$RESOURCE_BUNDLE_NAME"
  test -x "$build_binary"
  test -d "$build_resource_bundle"
  test -f "$build_resource_bundle/FermixPet.icns"
  stage_app_bundle "$build_binary" "$build_resource_bundle"
}

install_app() {
  mkdir -p "$INSTALL_DIR"
  rm -rf "$INSTALLED_APP"
  /usr/bin/ditto "$APP_BUNDLE" "$INSTALLED_APP"
  echo "Installed $INSTALLED_APP"
}

open_app() {
  local open_args=(-n)

  if [[ -n "${FERMIX_HOME:-}" ]]; then
    open_args+=(--env "FERMIX_HOME=$FERMIX_HOME")
  fi

  open_args+=("$APP_BUNDLE")
  /usr/bin/open "${open_args[@]}"
}

usage() {
  echo "usage: $0 [run|install|--debug|--logs|--telemetry|--verify]" >&2
}

validate_paths
stop_running_app
build_app_bundle

case "$MODE" in
  run)
    open_app
    ;;
  install|--install)
    install_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    usage
    exit 2
    ;;
esac
