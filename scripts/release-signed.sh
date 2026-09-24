#!/bin/bash
# Builds a universal, Developer ID signed, notarized and stapled Rekord.app and zips it.
#
# Needs: a "Developer ID Application" certificate in your keychain, XcodeGen, and notarytool
# credentials saved once with:
#   xcrun notarytool store-credentials <profile-name> --apple-id <you@example.com> --team-id <TEAMID>
#
# Usage:   NOTARY_PROFILE=<profile-name> scripts/release-signed.sh
# Testing: SKIP_NOTARIZE=1 scripts/release-signed.sh   (build and sign only; the zip is NOT distributable)
# Resume:  NOTARY_PROFILE=<profile-name> scripts/release-signed.sh --resume <submission-id>
#          Reuses the app already built in build/signed and picks up an existing Apple submission,
#          for when a run was interrupted (for example, the network dropped while waiting).
set -euo pipefail
cd "$(dirname "$0")/.."

RESUME_ID=""
if [ "${1:-}" = "--resume" ]; then
  RESUME_ID="${2:?Usage: --resume <submission-id>}"
fi

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

if [ -z "$RESUME_ID" ]; then
  xcodegen generate
  rm -rf build/signed
  xcodebuild -project Rekord.xcodeproj -scheme Rekord -configuration Release \
    -derivedDataPath build/signed \
    ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM_ID" \
    OTHER_CODE_SIGN_FLAGS="--timestamp" build | grep -E "BUILD|error:" || true
else
  echo "==> Resuming submission $RESUME_ID with the app already in build/signed"
  [ -d "$APP" ] || { echo "No built app at $APP to resume with" >&2; exit 1; }
fi

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

# Polls instead of using `notarytool submit --wait`, which gives up for good if the connection drops.
wait_for_apple() {
  local status out
  while true; do
    if out=$(xcrun notarytool info "$1" --keychain-profile "$NOTARY_PROFILE" --output-format json 2>/dev/null); then
      status=$(echo "$out" | plutil -extract status raw -o - -)
      echo "    $(date +%H:%M) status: $status"
      case "$status" in
        Accepted) return 0 ;;
        Invalid|Rejected) return 1 ;;
      esac
    else
      echo "    $(date +%H:%M) could not reach Apple, retrying"
    fi
    sleep 30
  done
}

if [ -z "$RESUME_ID" ]; then
  echo "==> Submitting to Apple for notarization (a first submission from a new account can take hours)"
  ditto -c -k --keepParent "$APP" build/signed/notarize.zip
  SUBMISSION_ID=$(xcrun notarytool submit build/signed/notarize.zip --keychain-profile "$NOTARY_PROFILE" --output-format json | plutil -extract id raw -o - -)
  echo "==> Submission id: $SUBMISSION_ID (resume with: scripts/release-signed.sh --resume $SUBMISSION_ID)"
else
  SUBMISSION_ID="$RESUME_ID"
fi

if ! wait_for_apple "$SUBMISSION_ID"; then
  echo "Notarization was not accepted. Apple's log:" >&2
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
