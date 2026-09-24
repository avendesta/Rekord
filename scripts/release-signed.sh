#!/bin/bash
# Builds a universal, Developer ID signed, notarized and stapled Rekord.app and zips it.
#
# Needs: a "Developer ID Application" certificate in your keychain, XcodeGen, and notarytool
# credentials saved once with:
#   xcrun notarytool store-credentials <profile-name> --apple-id <you@example.com> --team-id <TEAMID>
#
# Usage:   NOTARY_PROFILE=<profile-name> scripts/release-signed.sh
# Testing: SKIP_NOTARIZE=1 scripts/release-signed.sh   (build and sign only; the zip is NOT distributable)
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -z "${SKIP_NOTARIZE:-}" ]; then
  : "${NOTARY_PROFILE:?Set NOTARY_PROFILE to the notarytool keychain profile name}"
fi

IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -1)
[ -n "$IDENTITY" ] || { echo "No 'Developer ID Application' certificate found in the keychain." >&2; exit 1; }
TEAM_ID=$(echo "$IDENTITY" | sed -n 's/.*(\([A-Z0-9]*\))$/\1/p')
VERSION=$(awk -F'"' '/MARKETING_VERSION/ {print $2; exit}' project.yml)
APP=build/signed/Build/Products/Release/Rekord.app
ZIP="build/signed/Rekord-$VERSION.zip"

echo "==> Signing as: $IDENTITY"
echo "==> Version:    $VERSION"

xcodegen generate
rm -rf build/signed
xcodebuild -project Rekord.xcodeproj -scheme Rekord -configuration Release \
  -derivedDataPath build/signed \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM_ID" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" build | grep -E "BUILD|error:" || true

# Capture output first: `cmd | grep -q` under pipefail can fail spuriously when grep exits early.
[ "$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")" = "$VERSION" ] || { echo "App version mismatch" >&2; exit 1; }
ARCHS=$(lipo -archs "$APP/Contents/MacOS/Rekord")
[[ "$ARCHS" == *arm64* && "$ARCHS" == *x86_64* ]] || { echo "Not a universal binary: $ARCHS" >&2; exit 1; }
codesign --verify --deep --strict "$APP"
SIGNATURE=$(codesign -dv "$APP" 2>&1)
[[ "$SIGNATURE" == *"flags=0x10000(runtime)"* ]] || { echo "Hardened runtime is not enabled" >&2; exit 1; }
ENTITLEMENTS=$(codesign -d --entitlements - --xml "$APP" 2>/dev/null || true)
[[ "$ENTITLEMENTS" != *get-task-allow* ]] || { echo "App contains get-task-allow; notarization would reject it" >&2; exit 1; }

if [ -n "${SKIP_NOTARIZE:-}" ]; then
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "==> SKIP_NOTARIZE set: signed but NOT notarized, do not distribute: $ZIP"
  exit 0
fi

echo "==> Submitting to Apple for notarization (this usually takes a few minutes)"
ditto -c -k --keepParent "$APP" build/signed/notarize.zip
RESULT=$(xcrun notarytool submit build/signed/notarize.zip --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)
STATUS=$(echo "$RESULT" | plutil -extract status raw -o - -)
SUBMISSION_ID=$(echo "$RESULT" | plutil -extract id raw -o - -)
if [ "$STATUS" != "Accepted" ]; then
  echo "Notarization finished with status: $STATUS" >&2
  xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" >&2 || true
  exit 1
fi

echo "==> Accepted. Stapling the ticket"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -vv -t exec "$APP"

rm -f build/signed/notarize.zip
ditto -c -k --keepParent "$APP" "$ZIP"
echo "==> Done: $ZIP"
shasum -a 256 "$ZIP"
