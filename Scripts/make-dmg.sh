#!/bin/bash
# Builds Obscura-<version>_<build>.dmg with an Applications symlink from a built, signed Obscura.app. The update feed
# for it is then written by Scripts/make-feed.sh (G-33); an installed Obscura opens it read-only and copies the one
# app at its top level, so keep exactly one .app in it.
set -euo pipefail
APP="${1:?path to Obscura.app}"; OUT="${2:-dist}"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")
mkdir -p "$OUT"; STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
DMG="$OUT/Obscura-${VERSION}_${BUILD}.dmg"
hdiutil create -volname "Obscura" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
[ "${SIGNING_IDENTITY:--}" != "-" ] && codesign --timestamp -s "$SIGNING_IDENTITY" "$DMG" || true
echo "$DMG"
