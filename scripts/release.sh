#!/usr/bin/env bash
# Builds a notarized, stapled LocalTutor.app and zips it for distribution.
#
# Prerequisites (one-time):
#   1. A "Developer ID Application" certificate in your login keychain.
#   2. A notarytool keychain profile:
#        xcrun notarytool store-credentials "LocalTutorNotary" \
#          --apple-id "<apple-id>" --team-id "<TEAMID>" --password "<app-specific-password>"
#   3. Set DEVELOPMENT_TEAM below or export it before running.
#
# Usage: scripts/release.sh [version]
set -euo pipefail

VERSION="${1:-$(date +%Y.%m.%d)}"
TEAM_ID="${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM to your Apple team ID}"
NOTARY_PROFILE="${NOTARY_PROFILE:-LocalTutorNotary}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/release"
ARCHIVE="$BUILD/LocalTutor.xcarchive"
EXPORT="$BUILD/export"

rm -rf "$BUILD"
mkdir -p "$BUILD"

sed "s/__TEAM_ID__/$TEAM_ID/" "$ROOT/scripts/ExportOptions.plist" > "$BUILD/ExportOptions.plist"

xcodebuild archive \
  -project "$ROOT/LocalTutor.xcodeproj" \
  -scheme LocalTutor \
  -configuration Release \
  -archivePath "$ARCHIVE" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  MARKETING_VERSION="$VERSION"

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT" \
  -exportOptionsPlist "$BUILD/ExportOptions.plist"

APP="$EXPORT/LocalTutor.app"
ZIP="$BUILD/LocalTutor-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"

rm "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Notarized build: $ZIP"
