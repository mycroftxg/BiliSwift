#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
if [[ "$CONFIG" != debug && "$CONFIG" != release ]]; then
  print -u2 'Usage: build-app.sh [debug|release]'
  exit 2
fi
swift build --package-path "$ROOT" -c "$CONFIG" --product HarborBili
BIN_DIR="$(swift build --package-path "$ROOT" -c "$CONFIG" --show-bin-path)"
PARENT="$(dirname "$ROOT")"
APP="$PARENT/BiliSwift.app"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/BiliSwift-build.XXXXXX")"
trap 'if [[ -d "$STAGE/Previous.app" && ! -e "$APP" ]]; then mv "$STAGE/Previous.app" "$APP"; fi; rm -rf "$STAGE"' EXIT
BUNDLE="$STAGE/BiliSwift.app"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN_DIR/HarborBili" "$BUNDLE/Contents/MacOS/BiliSwift"
cp "$ROOT/Scripts/Info.plist" "$BUNDLE/Contents/Info.plist"
if [[ -f "$ROOT/Assets/AppIcon.icns" ]]; then cp "$ROOT/Assets/AppIcon.icns" "$BUNDLE/Contents/Resources/AppIcon.icns"; fi
xattr -cr "$BUNDLE" 2>/dev/null || true
codesign --force --sign - --entitlements "$ROOT/Scripts/HarborBili.entitlements" "$BUNDLE"
xattr -cr "$BUNDLE" 2>/dev/null || true
codesign --verify --strict "$BUNDLE"
if [[ -e "$APP" ]]; then mv "$APP" "$STAGE/Previous.app"; fi
mv "$BUNDLE" "$APP"
print "Built: $APP"
print 'If BiliSwift is already running, quit and reopen it to load the new executable.'
