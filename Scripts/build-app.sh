#!/bin/bash
# Builds Cadenza.app into ./build using only the Swift toolchain (no Xcode project needed).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="2.3.0"
APP="build/Cadenza.app"

# Universal binary: build each architecture, then merge. Both builds write to the same output
# folder, so copy each binary out before building the next.
SLICES="build/slices"
rm -rf "$SLICES"
mkdir -p "$SLICES"
for ARCH in arm64 x86_64; do
    TRIPLE="$ARCH-apple-macosx14.0"
    swift build -c release --triple "$TRIPLE"
    cp "$(swift build -c release --triple "$TRIPLE" --show-bin-path)/Cadenza" "$SLICES/Cadenza-$ARCH"
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "$SLICES"/Cadenza-* -output "$APP/Contents/MacOS/Cadenza"
rm -rf "$SLICES"

ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
swift Scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Cadenza</string>
    <key>CFBundleDisplayName</key><string>Cadenza</string>
    <key>CFBundleIdentifier</key><string>io.github.cadenza-player.Cadenza</string>
    <key>CFBundleExecutable</key><string>Cadenza</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHumanReadableCopyright</key><string>Unofficial client. Not affiliated with Google or YouTube.</string>
</dict>
</plist>
EOF

codesign --force --sign - "$APP"
echo "Built $APP"
