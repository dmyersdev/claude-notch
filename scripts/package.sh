#!/bin/sh
# Builds a release of Claude Notch and zips it for sharing.
#
#   scripts/package.sh 1.0          -> dist/Claude-Notch-1.0.zip
#   scripts/package.sh 1.1 7        -> version 1.1, build 7
#
# The app is signed ad hoc (no Apple Developer ID), so on first open people allow it once in
# System Settings > Privacy & Security > Open Anyway.
set -eu

version="${1:?usage: scripts/package.sh <version> [build-number]}"
build="${2:-$(git rev-list --count HEAD)}"
root="$(cd "$(dirname "$0")/.." && pwd)"
derived="$root/build/release"
app="$derived/Build/Products/Release/Claude Notch.app"
zip="$root/dist/Claude-Notch-$version.zip"

cd "$root"
xcodegen generate --quiet
rm -rf "$derived"
xcodebuild -scheme ClaudeNotch -configuration Release -derivedDataPath "$derived" \
    -destination 'generic/platform=macOS' \
    MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build" \
    CODE_SIGN_IDENTITY=- build -quiet

# Re-sign the whole bundle ad hoc so its signature is consistent after the build.
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"

mkdir -p dist
rm -f "$zip"
# ditto keeps the bundle's symlinks and metadata intact, unlike plain zip.
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"

echo "Built $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")" \
     "($(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$app/Contents/Info.plist")):" \
     "$(lipo -archs "$app/Contents/MacOS/Claude Notch")"
echo "$zip ($(du -h "$zip" | cut -f1))"
