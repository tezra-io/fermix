#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="FermixPet"
BUNDLE_ID="io.tezra.FermixPet"
MIN_SYSTEM_VERSION="13.0"
RESOURCE_BUNDLE_NAME="FermixPet_FermixPet.bundle"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGING_DIR="$ROOT_DIR/.build/app"
APP_BUNDLE="$STAGING_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"

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

stage_app_bundle() {
  local build_binary="$1"
  local build_resource_bundle="$2"

  rm -rf "$APP_BUNDLE"
  mkdir -p "$APP_MACOS" "$APP_RESOURCES"
  cp "$build_binary" "$APP_BINARY"
  cp "$build_resource_bundle/FermixPet.icns" "$APP_RESOURCES/FermixPet.icns"
  cp -R "$build_resource_bundle" "$APP_BUNDLE/$RESOURCE_BUNDLE_NAME"
  chmod +x "$APP_BINARY"
  write_info_plist
}

build_app_bundle() {
  cd "$ROOT_DIR"
  swift build

  local build_dir
  build_dir="$(swift build --show-bin-path)"

  local build_binary="$build_dir/$APP_NAME"
  local build_resource_bundle="$build_dir/$RESOURCE_BUNDLE_NAME"
  test -x "$build_binary"
  test -d "$build_resource_bundle"
  test -f "$build_resource_bundle/FermixPet.icns"
  stage_app_bundle "$build_binary" "$build_resource_bundle"
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
  echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
}

stop_running_app
build_app_bundle

case "$MODE" in
  run)
    open_app
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
