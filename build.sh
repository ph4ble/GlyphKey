#!/bin/sh
# Build MouseGestureKey: a CLI binary AND a double-clickable .app.
set -e
cd "$(dirname "$0")"

APP=MouseGestureKey.app
BIN="$APP/Contents/MacOS/MouseGestureKey"

echo "==> Compiling CLI binary"
swiftc -swift-version 5 -O Engine.swift mousegesturekey.swift -o MouseGestureKey

echo "==> Compiling .app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -swift-version 5 -O \
    -framework AppKit -framework ApplicationServices \
    -framework CoreGraphics -framework CoreFoundation \
    Engine.swift MouseGestureApp.swift -o "$BIN"

echo "==> Writing Info.plist"
cp Info.plist "$APP/Contents/Info.plist"

echo "==> Ad-hoc code signing (local use)"
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "  (codesign unavailable; app may need manual signing)"

echo "OK"
echo "  CLI : ./MouseGestureKey   (./MouseGestureKey --selftest to self-test)"
echo "  APP : open $APP   (double-click it in Finder)"
