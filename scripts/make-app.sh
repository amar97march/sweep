#!/bin/sh
# Builds Sweep.app (release, ad-hoc signed) into .build/Sweep.app.
# UNIVERSAL=1 builds for Apple silicon and Intel; VERSION=0.1.0 sets the version shown in Finder.
set -eu
cd "$(dirname "$0")/.."

if [ "${UNIVERSAL:-0}" = 1 ]; then
    swift build -c release --product SweepApp --arch arm64 --arch x86_64
    binary=.build/out/Products/Release/SweepApp
else
    swift build -c release --product SweepApp
    binary=.build/release/SweepApp
fi
app=.build/Sweep.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/Sweep"

iconset=.build/AppIcon.iconset
swift scripts/make-icon.swift "$iconset" >/dev/null
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"

version=${VERSION:-$(git describe --tags --always 2>/dev/null || echo 0.1.0)}
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Sweep</string>
    <key>CFBundleIdentifier</key><string>org.sweep.Sweep</string>
    <key>CFBundleName</key><string>Sweep</string>
    <key>CFBundleDisplayName</key><string>Sweep</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSDesktopFolderUsageDescription</key><string>Sweep measures the files in your Desktop folder to show what uses space.</string>
    <key>NSDocumentsFolderUsageDescription</key><string>Sweep measures the files in your Documents folder to show what uses space.</string>
    <key>NSDownloadsFolderUsageDescription</key><string>Sweep measures the files in your Downloads folder to show what uses space.</string>
    <key>NSRemovableVolumesUsageDescription</key><string>Sweep measures files on external drives to show what uses space.</string>
    <key>NSNetworkVolumesUsageDescription</key><string>Sweep measures files on network drives to show what uses space.</string>
</dict>
</plist>
PLIST

# Ad-hoc signatures normally pin permissions (Full Disk Access, login item, notifications) to this exact
# build, so macOS silently stops honouring them after a rebuild. Naming the bundle identifier as the
# designated requirement keeps them across local rebuilds. A Developer ID signature replaces this for release.
codesign --force --sign - --requirements '=designated => identifier "org.sweep.Sweep"' "$app"
echo "built $app"
