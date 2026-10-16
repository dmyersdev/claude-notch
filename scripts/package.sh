#!/bin/sh
# Builds a release of Claude Notch and zips it for sharing.
#
#   scripts/package.sh 2.1          -> dist/Claude-Notch-2.1.zip
#   scripts/package.sh 2.1 42       -> version 2.1, build 42
#
# Signed ad hoc by default, so people allow it once with Open Anyway. With a Developer ID it's signed for real
# and notarized, so it opens like any other app:
#
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_KEY=/path/AuthKey_ABC123.p8 NOTARY_KEY_ID=ABC123 NOTARY_ISSUER=<issuer-uuid> \
#   scripts/package.sh 2.1
set -eu

version="${1:?usage: scripts/package.sh <version> [build-number]}"
build="${2:-$(git rev-list --count HEAD)}"
root="$(cd "$(dirname "$0")/.." && pwd)"
derived="$root/build/release"
app="$derived/Build/Products/Release/Claude Notch.app"
zip="$root/dist/Claude-Notch-$version.zip"
identity="${SIGN_IDENTITY:--}"

cd "$root"
xcodegen generate --quiet
rm -rf "$derived"
xcodebuild -scheme ClaudeNotch -configuration Release -derivedDataPath "$derived" \
    -destination 'generic/platform=macOS' \
    MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build" \
    CODE_SIGN_IDENTITY=- build -quiet

if [ "$identity" = "-" ]; then
    # Ad hoc: consistent signature, no Apple account needed.
    codesign --force --deep --sign - "$app"
else
    # Developer ID: hardened runtime and a secure timestamp, both required for notarization.
    codesign --force --deep --options runtime --timestamp \
        --entitlements ClaudeNotch/ClaudeNotch.entitlements --sign "$identity" "$app"
fi
codesign --verify --deep --strict "$app"

mkdir -p dist
rm -f "$zip"
# ditto keeps the bundle's symlinks and metadata intact, unlike plain zip.
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"

if [ "$identity" != "-" ] && [ -n "${NOTARY_KEY:-}" ]; then
    xcrun notarytool submit "$zip" --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait
    xcrun stapler staple "$app"
    rm -f "$zip"
    ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
    spctl --assess --type execute --verbose "$app"
fi

echo "Built $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")" \
     "($(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$app/Contents/Info.plist")):" \
     "$(lipo -archs "$app/Contents/MacOS/Claude Notch")"
echo "$zip ($(du -h "$zip" | cut -f1))"
