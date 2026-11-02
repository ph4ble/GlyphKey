#!/bin/sh
# Build GlyphKey (指诀): a CLI binary AND a double-clickable .app.
set -e
cd "$(dirname "$0")"

APP=GlyphKey.app
BIN="$APP/Contents/MacOS/GlyphKey"

echo "==> Compiling CLI binary"
swiftc -swift-version 5 -O -framework ApplicationServices -framework CoreGraphics Engine.swift glyphkey.swift -o GlyphKey

echo "==> Compiling .app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -swift-version 5 -O \
    -framework AppKit -framework ApplicationServices \
    -framework ServiceManagement \
    -framework CoreGraphics -framework CoreFoundation \
    Engine.swift GlyphKeyApp.swift -o "$BIN"

echo "==> Writing Info.plist"
cp Info.plist "$APP/Contents/Info.plist"

echo "==> Code signing"
CERT="MouseGestureKey Local Signing"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT"; then
  # Stable local cert: permission grants survive rebuilds (re-grant only once).
  codesign --force --deep --sign "$CERT" --options runtime "$APP" 2>/dev/null || echo "  (app codesign failed)"
  codesign --force --sign "$CERT" --options runtime GlyphKey 2>/dev/null || echo "  (cli codesign failed)"
  echo "  signed with stable cert: $CERT"
else
  echo "  (cert '$CERT' not found -> ad-hoc; re-grant permissions after each rebuild)"
  codesign --force --deep --sign - "$APP" 2>/dev/null || echo "  (codesign unavailable; app may need manual signing)"
fi

echo "OK"
echo "  CLI : ./GlyphKey   (./GlyphKey --selftest to self-test)"
echo "  APP : open $APP   (double-click it in Finder)"
