#!/usr/bin/env bash
# Builds a release "Veery Mail.app" into ./build. Requires Xcode 15.3+ (Swift 5.10) on macOS 14+.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/VeeryMail"

APP="build/Veery Mail.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/VeeryMail"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature so Keychain and notifications work locally.
codesign --force --deep --sign - "$APP"

echo "Built $APP ($(du -sh "$APP" | cut -f1))"
echo "Run:      open \"$APP\""
echo "Install:  cp -R \"$APP\" /Applications/"
