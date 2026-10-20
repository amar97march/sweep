#!/bin/sh
# Builds dist/Sweep-<version>.dmg for a release: a universal Sweep.app next to a link to Applications,
# so people can drag it straight in. VERSION=0.1.0 sets the version (defaults to the git description).
set -eu
cd "$(dirname "$0")/.."

version=${VERSION:-$(git describe --tags --always 2>/dev/null || echo 0.1.0)}
VERSION="$version" UNIVERSAL=1 sh scripts/make-app.sh

staging=.build/dmg
rm -rf "$staging"
mkdir -p "$staging" dist
cp -R .build/Sweep.app "$staging/"
ln -s /Applications "$staging/Applications"
# The disk's own icon in Finder.
cp .build/Sweep.app/Contents/Resources/AppIcon.icns "$staging/.VolumeIcon.icns"
if command -v SetFile >/dev/null; then SetFile -a C "$staging"; fi

dmg="dist/Sweep-$version.dmg"
rm -f "$dmg"
hdiutil create -volname "Sweep" -srcfolder "$staging" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$dmg" >/dev/null
echo "built $dmg ($(du -h "$dmg" | cut -f1))"
