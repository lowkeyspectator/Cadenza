#!/bin/bash
# Builds Cadenza.app and packages it as build/Cadenza-<version>.dmg, with an Applications
# shortcut so it can be installed by dragging.
#
# Notarized release (opens on other Macs with no security prompt):
#   NOTARY_PROFILE=cadenza-notary ./Scripts/make-dmg.sh
# needs a "Developer ID Application" certificate in the keychain and a notarytool profile
# created once with `xcrun notarytool store-credentials cadenza-notary`. See the README.
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

if [ -n "${NOTARY_PROFILE:-}" ]; then
    SIGNER=$(codesign -dvv build/Cadenza.app 2>&1 | sed -n 's/^Authority=\(Developer ID Application: .*\)/\1/p' | head -1)
    if [ -z "$SIGNER" ]; then
        echo "error: the app is not signed with a Developer ID Application certificate, so it cannot be notarized." >&2
        exit 1
    fi
    codesign --force --timestamp --sign "$SIGNER" "$DMG"
    echo "Submitting $DMG to Apple's notary service (usually a few minutes)…"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature -v "$DMG"
    echo "Notarized $DMG"
else
    echo "Built $DMG (not notarized; set NOTARY_PROFILE to notarize)"
fi
