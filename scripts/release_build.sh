#!/usr/bin/env bash
# Builds, signs, notarizes, and packages a Developer ID release of Moodpaper.
#
# Prerequisites (one-time, done outside this script):
#   1. A "Developer ID Application" certificate in the login keychain
#      (maintainer certificate for team Z52AX2BH7T).
#   2. Notarization credentials stored under keychain profile "Moodpaper":
#        xcrun notarytool store-credentials "Moodpaper" \
#          --apple-id "you@example.com" --team-id Z52AX2BH7T
#      (generates an app-specific password prompt; run this yourself, once).
#
# Usage: scripts/release_build.sh
# Output: build/release/Moodpaper-<version>.dmg

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

SCHEME="Moodpaper"
PROJECT="Moodpaper.xcodeproj"
KEYCHAIN_PROFILE="Moodpaper"
BUILD_DIR="$ROOT_DIR/build/release"
ARCHIVE_PATH="$BUILD_DIR/Moodpaper.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
EXPORT_OPTIONS="$ROOT_DIR/scripts/exportOptions.plist"

VERSION=$(defaults read "$ROOT_DIR/Moodpaper/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "")
if [ -z "$VERSION" ]; then
  VERSION=$(/usr/libexec/PlistBuddy -c "Print :MARKETING_VERSION" "$ROOT_DIR/$PROJECT/project.pbxproj" 2>/dev/null || echo "1.0.0")
fi
# Fall back to reading straight from the pbxproj build setting if Info.plist
# hasn't been substituted (it uses $(MARKETING_VERSION), not a literal value).
VERSION=$(grep -m1 "MARKETING_VERSION = " "$ROOT_DIR/$PROJECT/project.pbxproj" | sed -E 's/.*MARKETING_VERSION = ([0-9.]+);/\1/')

DMG_PATH="$BUILD_DIR/Moodpaper-$VERSION.dmg"

echo "==> Cleaning previous release build"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> Running the test suite (Debug config: Release is signed Developer ID,"
echo "    which xcodebuild cannot launch/instrument for testing)"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug test

echo "==> Archiving (Release, Developer ID signing)"
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  -allowProvisioningUpdates

echo "==> Exporting signed .app from archive"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -allowProvisioningUpdates

APP_PATH="$EXPORT_PATH/Moodpaper.app"
if [ ! -d "$APP_PATH" ]; then
  echo "error: exported app not found at $APP_PATH"
  exit 1
fi

echo "==> Verifying code signature and hardened runtime"
codesign -dv --verbose=4 "$APP_PATH" 2>&1 | tee "$BUILD_DIR/codesign-report.txt"
if ! grep -q "flags=0x10000(runtime)" "$BUILD_DIR/codesign-report.txt"; then
  echo "error: hardened runtime flag not present on the exported app"
  exit 1
fi
if ! grep -q "Developer ID Application" "$BUILD_DIR/codesign-report.txt"; then
  echo "error: app is not signed with a Developer ID Application identity"
  exit 1
fi

echo "==> Building the .dmg"
STAGING_DIR="$BUILD_DIR/dmg-staging"
mkdir -p "$STAGING_DIR"
cp -R "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"
hdiutil create -volname "Moodpaper" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_PATH"
rm -rf "$STAGING_DIR"

echo "==> Signing the .dmg"
DEV_ID_IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/')
if [ -z "$DEV_ID_IDENTITY" ]; then
  echo "error: no Developer ID Application identity found in the keychain"
  exit 1
fi
codesign --sign "$DEV_ID_IDENTITY" --timestamp "$DMG_PATH"

echo "==> Checking for notarization credentials (keychain profile: $KEYCHAIN_PROFILE)"
if ! xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" >/dev/null 2>&1; then
  echo ""
  echo "No notarization credentials found under keychain profile \"$KEYCHAIN_PROFILE\"."
  echo "Signed, unsigned-notarization .dmg is ready at:"
  echo "  $DMG_PATH"
  echo ""
  echo "Set up credentials once with:"
  echo "  xcrun notarytool store-credentials \"$KEYCHAIN_PROFILE\" --apple-id \"you@example.com\" --team-id Z52AX2BH7T"
  echo "then re-run this script to notarize and staple."
  exit 0
fi

echo "==> Submitting for notarization (this can take a few minutes)"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$KEYCHAIN_PROFILE" --wait

echo "==> Stapling the notarization ticket"
xcrun stapler staple "$DMG_PATH"

echo "==> Verifying Gatekeeper acceptance"
spctl -a -vvv -t open --context context:primary-signature "$DMG_PATH"

echo ""
echo "Release ready: $DMG_PATH"
