#!/usr/bin/env bash
# build-release.sh — build a Developer ID–signed, notarized MokaScreen.app and zip it.
#
# Usage:
#   ./build-release.sh            sign, notarize, staple, zip
#   NOTARIZE=0 ./build-release.sh sign and zip only (Gatekeeper will warn on other Macs)
#
# The zip lands in ~/MokaScreenReleases. Copy it to the other Mac (AirDrop, or over the
# Thunderbolt Bridge), unzip, and drag MokaScreen to /Applications. A notarized app opens
# on an MDM-managed Mac without needing Xcode or an admin override.
#
# One-time prerequisite: a notarytool keychain profile for team G3RSHR4W5U. MokaRig's
# profile works because notarization credentials are per team, not per app:
#   xcrun notarytool store-credentials "mokarig-notary" \
#       --apple-id <apple-id> --team-id G3RSHR4W5U --password <app-specific-pw>
#
# Run from the repo root (where MokaScreen.xcodeproj lives).

set -euo pipefail

SCHEME="MokaScreen"
PROJECT="MokaScreen.xcodeproj"
TEAM_ID="G3RSHR4W5U"
NOTARY_PROFILE="${NOTARY_PROFILE:-mokarig-notary}"
NOTARIZE="${NOTARIZE:-1}"
OUT_DIR="$HOME/MokaScreenReleases"
BUILD_DIR="build/release"

VERSION=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release -showBuildSettings 2>/dev/null \
	| awk -F' = ' '/ MARKETING_VERSION = / { print $2; exit }')
STAMP=$(date +%Y%m%d-%H%M)
NAME="MokaScreen-$VERSION-$STAMP"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$OUT_DIR"

echo "==> Archiving $SCHEME $VERSION"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
	-archivePath "$BUILD_DIR/MokaScreen.xcarchive" -allowProvisioningUpdates \
	-destination "generic/platform=macOS" -quiet archive

echo "==> Exporting with Developer ID"
cat > "$BUILD_DIR/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>teamID</key>
	<string>$TEAM_ID</string>
	<key>signingStyle</key>
	<string>automatic</string>
</dict>
</plist>
EOF
xcodebuild -exportArchive -archivePath "$BUILD_DIR/MokaScreen.xcarchive" \
	-exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" -exportPath "$BUILD_DIR/export" \
	-allowProvisioningUpdates >/dev/null
APP="$BUILD_DIR/export/MokaScreen.app"
codesign --verify --strict --deep "$APP"

if [ "$NOTARIZE" = "1" ]; then
	echo "==> Notarizing (profile: $NOTARY_PROFILE)"
	ditto -c -k --keepParent "$APP" "$BUILD_DIR/notarize.zip"
	xcrun notarytool submit "$BUILD_DIR/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
	xcrun stapler staple "$APP"
	spctl --assess --type execute --verbose "$APP"
fi

ditto -c -k --keepParent "$APP" "$OUT_DIR/$NAME.zip"
echo "==> $OUT_DIR/$NAME.zip"
