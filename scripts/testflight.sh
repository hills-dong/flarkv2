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
#   BUILD_NUMBER       default: unix timestamp
set -euo pipefail

cd "$(dirname "$0")/.."
: "${DEVELOPMENT_TEAM:?set DEVELOPMENT_TEAM}"
: "${ASC_KEY_ID:?set ASC_KEY_ID}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
: "${ASC_KEY_PATH:?set ASC_KEY_PATH (path to .p8)}"
BUNDLE_ID="${BUNDLE_ID:-app.flark.bogota}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%s)}"

ARCHIVE="build/Flark.xcarchive"
EXPORT_DIR="build/export"
EXPORT_PLIST="build/ExportOptions.generated.plist"

echo "▸ regenerating project"
xcodegen generate >/dev/null

echo "▸ archiving (iOS, automatic signing, build $BUILD_NUMBER)"
xcodebuild -project Flark.xcodeproj -scheme Flark \
  -destination 'generic/platform=iOS' -configuration Release \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
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
