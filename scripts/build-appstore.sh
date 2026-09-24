#!/bin/bash
# Archives the sandboxed Mac App Store build and exports (or uploads) the package.
#
# Needs: Xcode signed in to your Apple Developer account (Xcode > Settings > Accounts), your team ID
# in Local.xcconfig, and an app record for the bundle ID in App Store Connect.
#
# Usage:            scripts/build-appstore.sh            archive + export a .pkg to build/appstore/
#                   UPLOAD=1 scripts/build-appstore.sh   archive + upload straight to App Store Connect
#                   ARCHIVE_ONLY=1 scripts/build-appstore.sh   stop after the archive (a dry run)
set -euo pipefail
cd "$(dirname "$0")/.."

TEAM_ID="${TEAM_ID:-$(sed -n 's/^ *DEVELOPMENT_TEAM *= *\([A-Z0-9]*\).*/\1/p' Local.xcconfig 2>/dev/null | head -1)}"
[ -n "$TEAM_ID" ] || { echo "Set your team ID in Local.xcconfig (DEVELOPMENT_TEAM = ...) or pass TEAM_ID=" >&2; exit 1; }
VERSION=$(awk -F'"' '/MARKETING_VERSION/ {print $2; exit}' project.yml)
BUILD=$(awk -F'"' '/CURRENT_PROJECT_VERSION/ {print $2; exit}' project.yml)
ARCHIVE=build/appstore/Rekord.xcarchive
APP="$ARCHIVE/Products/Applications/Rekord.app"

echo "==> Rekord $VERSION (build $BUILD), team $TEAM_ID"
xcodegen generate
rm -rf build/appstore
xcodebuild archive -project Rekord.xcodeproj -scheme Rekord -configuration Release \
  -archivePath "$ARCHIVE" \
  CODE_SIGN_ENTITLEMENTS=Rekord/Resources/RekordAppStore.entitlements | grep -E "ARCHIVE|error:" || true

# The sandbox must actually be in the archive, or App Store Connect rejects the upload.
[ -d "$APP" ] || { echo "Archive failed: no app at $APP" >&2; exit 1; }
ENTITLEMENTS=$(codesign -d --entitlements - --xml "$APP" 2>/dev/null || true)
[[ "$ENTITLEMENTS" == *com.apple.security.app-sandbox* ]] || { echo "The archived app is not sandboxed" >&2; exit 1; }
[[ "$ENTITLEMENTS" != *get-task-allow* ]] || { echo "The archived app contains get-task-allow" >&2; exit 1; }
[ -f "$APP/Contents/Resources/PrivacyInfo.xcprivacy" ] || { echo "The privacy manifest is missing from the app" >&2; exit 1; }
echo "==> Archive OK: sandboxed, privacy manifest present"
[ -z "${ARCHIVE_ONLY:-}" ] || exit 0

DESTINATION=export
[ -z "${UPLOAD:-}" ] || DESTINATION=upload
cat > build/appstore/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>app-store-connect</string>
	<key>destination</key><string>$DESTINATION</string>
	<key>teamID</key><string>$TEAM_ID</string>
	<key>signingStyle</key><string>automatic</string>
	<key>uploadSymbols</key><true/>
</dict>
</plist>
PLIST

echo "==> Exporting ($DESTINATION)"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist build/appstore/ExportOptions.plist \
  -exportPath build/appstore/export -allowProvisioningUpdates
if [ "$DESTINATION" = upload ]; then
  echo "==> Uploaded. Watch App Store Connect > TestFlight for processing (usually 5 to 30 minutes)."
else
  echo "==> Done: $(ls build/appstore/export/*.pkg)"
fi
