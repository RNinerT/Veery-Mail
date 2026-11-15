#!/usr/bin/env bash
# Builds, signs with Developer ID, notarizes and staples "Veery Mail.app", then zips it for download.
#
# Requires (on a Mac with Xcode 15.3+):
#   DEVELOPER_ID   e.g. "Developer ID Application: Your Name (TEAMID)"   (identity in your login keychain)
#   NOTARY_PROFILE name of a notarytool keychain profile, created once with:
#                  xcrun notarytool store-credentials "veery-notary" --apple-id <APPLE_ID> --team-id <TEAM_ID>
#                  (it prompts for an app-specific password; nothing secret is stored in this repo)
# Usage:
#   DEVELOPER_ID="Developer ID Application: … (TEAMID)" NOTARY_PROFILE=veery-notary ./scripts/release.sh
set -euo pipefail
cd "$(dirname "$0")/.."

: "${DEVELOPER_ID:?Set DEVELOPER_ID to your Developer ID Application identity}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to a notarytool keychain profile}"

APP="build/Veery Mail.app"
ZIP="build/Veery-Mail.zip"

# Universal binary so one download runs on Apple silicon and Intel Macs.
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/VeeryMail"

rm -rf "$APP" "$ZIP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/VeeryMail"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Hardened runtime + secure timestamp are required for notarization.
codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

# Re-zip so the download carries the stapled ticket.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
spctl --assess --type execute --verbose=4 "$APP"
shasum -a 256 "$ZIP"
echo "Ready: $ZIP"
