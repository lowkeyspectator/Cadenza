#!/bin/bash
# Builds Cadenza.app and packages it as build/Cadenza-<version>.dmg, with an Applications
# shortcut so it can be installed by dragging.
set -euo pipefail
cd "$(dirname "$0")/.."

./Scripts/build-app.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" build/Cadenza.app/Contents/Info.plist)
DMG="build/Cadenza-$VERSION.dmg"
STAGE="build/dmg"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R build/Cadenza.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Cadenza $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"
echo "Built $DMG"
