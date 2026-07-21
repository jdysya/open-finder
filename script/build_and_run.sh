#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="OpenFinder"
BUNDLE_ID="dev.openfinder.OpenFinder"
MIN_SYSTEM_VERSION="14.0"
DEFAULT_SIGNING_IDENTITY="OpenFinder Local Development"
SIGNING_IDENTITY="${OPENFINDER_SIGNING_IDENTITY:-$DEFAULT_SIGNING_IDENTITY}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
APP_ICON_SOURCE="$ROOT_DIR/Resources/OpenFinder.icns"
APP_ICON_NAME="OpenFinder.icns"
VIDEO_ANALYZER_PLUGIN="$APP_RESOURCES/BuiltinPlugins/video-analyzer.plugin"
VIDEO_ANALYZER_MANIFEST="$VIDEO_ANALYZER_PLUGIN/manifest.json"

assert_manifest_value() {
  local key="$1"
  local expected="$2"
  local actual
  actual="$(/usr/bin/plutil -extract "$key" raw -o - "$VIDEO_ANALYZER_MANIFEST")"
  if [[ "$actual" != "$expected" ]]; then
    echo "error: packaged Video Analyzer manifest $key is '$actual'; expected '$expected'" >&2
    exit 1
  fi
}

if [[ "$MODE" != "build" ]]; then
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
fi

swift build
BUILD_BINARY="$(swift build --show-bin-path)/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

if [ -d "$ROOT_DIR/ExamplePlugins" ]; then
  mkdir -p "$APP_RESOURCES/BuiltinPlugins"
  rsync -a \
    --exclude '.venv/' \
    --exclude '.pytest_cache/' \
    --exclude '.ruff_cache/' \
    --exclude '__pycache__/' \
    --exclude '*.pyc' \
    "$ROOT_DIR/ExamplePlugins/" "$APP_RESOURCES/BuiltinPlugins/"

  if [[ ! -f "$VIDEO_ANALYZER_MANIFEST" ]]; then
    echo "error: packaged Video Analyzer manifest is missing" >&2
    exit 1
  fi
  assert_manifest_value schemaVersion 2
  assert_manifest_value execution.type http
  assert_manifest_value execution.protocolVersion 1
  assert_manifest_value execution.endpointConfigurationKey serverURL
  assert_manifest_value execution.tokenSecretKey serverToken
  assert_manifest_value configuration.0.key serverURL
  assert_manifest_value configuration.0.default http://127.0.0.1:8765
  assert_manifest_value configuration.1.key useJoyTag
  assert_manifest_value configuration.1.default true
  assert_manifest_value permissions.network.required true
  assert_manifest_value permissions.network.hosts.0 127.0.0.1
  assert_manifest_value permissions.network.hosts.1 ::1
  assert_manifest_value permissions.localSecrets.0 serverToken
  assert_manifest_value permissions.runExternalCommands false
  if /usr/bin/plutil -extract runtime raw -o - "$VIDEO_ANALYZER_MANIFEST" >/dev/null 2>&1 ||
     /usr/bin/plutil -extract entry raw -o - "$VIDEO_ANALYZER_MANIFEST" >/dev/null 2>&1 ||
     /usr/bin/plutil -extract configuration.2 raw -o - "$VIDEO_ANALYZER_MANIFEST" >/dev/null 2>&1 ||
     /usr/bin/plutil -extract permissions.network.hosts.2 raw -o - "$VIDEO_ANALYZER_MANIFEST" >/dev/null 2>&1 ||
     /usr/bin/plutil -extract permissions.localSecrets.1 raw -o - "$VIDEO_ANALYZER_MANIFEST" >/dev/null 2>&1 ||
     /usr/bin/plutil -extract permissions.keychainSecrets.0 raw -o - "$VIDEO_ANALYZER_MANIFEST" >/dev/null 2>&1; then
    echo "error: packaged Video Analyzer manifest retains a process field or an extra configuration/permission" >&2
    exit 1
  fi
  if grep -Eiq '(^|[^[:alnum:]_])uv([^[:alnum:]_]|$)' "$VIDEO_ANALYZER_MANIFEST"; then
    echo "error: packaged Video Analyzer execution references uv" >&2
    exit 1
  fi
  if find "$VIDEO_ANALYZER_PLUGIN" -name '.venv' -print -quit | grep -q .; then
    echo "error: packaged Video Analyzer plugin contains .venv" >&2
    exit 1
  fi
  if [[ -e "$VIDEO_ANALYZER_PLUGIN/run.py" || -e "$VIDEO_ANALYZER_PLUGIN/worker" ]]; then
    echo "error: packaged Video Analyzer plugin contains the removed process bridge" >&2
    exit 1
  fi
fi

if [ -f "$APP_ICON_SOURCE" ]; then
  cp "$APP_ICON_SOURCE" "$APP_RESOURCES/$APP_ICON_NAME"
fi

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIconFile</key>
  <string>$APP_ICON_NAME</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>OpenFinder</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

sign_app_bundle() {
  local identities
  identities="$(security find-identity -p codesigning -v 2>/dev/null || true)"

  if grep -Fq -- "\"$SIGNING_IDENTITY\"" <<<"$identities"; then
    echo "Signing $APP_BUNDLE with identity: $SIGNING_IDENTITY"
    codesign --force --deep --timestamp=none --sign "$SIGNING_IDENTITY" "$APP_BUNDLE"
  else
    echo "warning: code-signing identity '$SIGNING_IDENTITY' is unavailable; using ad-hoc signing. Keychain and TCC approvals may not persist across rebuilds." >&2
    codesign --force --deep --timestamp=none --sign - "$APP_BUNDLE"
  fi

  codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
}

sign_app_bundle

case "$MODE" in
  build)
    exit 0
    ;;
esac

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

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
    echo "usage: $0 [run|build|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
