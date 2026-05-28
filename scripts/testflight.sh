#!/usr/bin/env bash
# Archive + upload Flark (iOS) to TestFlight, non-interactively, using an
# App Store Connect API key. Nothing here contains secrets — you supply them
# via env so credentials never enter the repo or chat.
#
# Required env:
#   DEVELOPMENT_TEAM   your 10-char Apple Team ID (App Store Connect → Membership)
#   ASC_KEY_ID         App Store Connect API key id
#   ASC_ISSUER_ID      App Store Connect API issuer id
#   ASC_KEY_PATH       absolute path to the AuthKey_XXXXXXXXXX.p8 file
# Optional:
#   BUNDLE_ID          default: app.flark.bogota  (must be registered/ownable by your team)
#   BUILD_NUMBER       default: YYYYMMDDHHMM (UTC)
#
# Note on the default: earlier uploads used `date +%s` (10-digit unix
# timestamp), but a separate upload used `date +%Y%m%d%H%M` (12-digit),
# which compares larger numerically. TestFlight orders builds by build
# number, so mixing the two makes "newer" uploads appear *below* older
# ones in the build list. Stick to 12-digit YYYYMMDDHHMM going forward.
set -euo pipefail

cd "$(dirname "$0")/.."
: "${DEVELOPMENT_TEAM:?set DEVELOPMENT_TEAM}"
: "${ASC_KEY_ID:?set ASC_KEY_ID}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
: "${ASC_KEY_PATH:?set ASC_KEY_PATH (path to .p8)}"
BUNDLE_ID="${BUNDLE_ID:-app.flark.bogota}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"

ARCHIVE="build/Flark.xcarchive"
EXPORT_DIR="build/export"
EXPORT_PLIST="build/ExportOptions.generated.plist"

echo "▸ regenerating project"
xcodegen generate >/dev/null

echo "▸ archiving (iOS, automatic signing, build $BUILD_NUMBER)"
# Note: deliberately not passing `PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE_ID` —
# that overrides ALL targets including app extensions, so the widget
# extension ended up with the same bundle ID as the main app and ASC
# rejected the archive with a CFBundleIdentifier collision. The main
# app's bundle ID is now read from project.yml (it matches `$BUNDLE_ID`
# anyway). The `BUNDLE_ID` env var remains a documented knob; if you
# ever need to override the main app's bundle ID for a side build, edit
# project.yml or pass `PRODUCT_BUNDLE_IDENTIFIER` only to the Flark
# target via the `-target Flark` flag.
xcodebuild -project Flark.xcodeproj -scheme Flark \
  -destination 'generic/platform=iOS' -configuration Release \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CODE_SIGN_STYLE=Automatic \
  clean archive

sed "s/__TEAM_ID__/$DEVELOPMENT_TEAM/" scripts/ExportOptions.plist > "$EXPORT_PLIST"

echo "▸ exporting + uploading to App Store Connect / TestFlight"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_PLIST" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"

echo "✅ Uploaded. It will appear in App Store Connect → TestFlight after"
echo "   Apple finishes processing (usually 5–30 min)."
