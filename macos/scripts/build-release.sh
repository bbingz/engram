#!/bin/bash
# macos/scripts/build-release.sh
# Release pipeline: xcodegen, archive, Developer ID export, optional notarization, final zip.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MACOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT="$MACOS_DIR/Engram.xcodeproj"
BUILD_DIR="$MACOS_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/Engram.xcarchive"
EXPORT_PATH="$BUILD_DIR/EngramExport"
RELEASE_DIR="$BUILD_DIR/EngramRelease"
EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.generated.plist"

SCHEME="Engram"
VERSION="${ENGRAM_RELEASE_VERSION:-1.0}"
RELEASE_ARCHS="${ENGRAM_RELEASE_ARCHS:-arm64 x86_64}"
NOTARY_PROFILE="${ENGRAM_NOTARY_PROFILE:-}"
TEAM_ID="${ENGRAM_TEAM_ID:-}"

if [[ -z "$TEAM_ID" ]]; then
  TEAM_ID=$(/usr/libexec/PlistBuddy -c "Print teamID" "$MACOS_DIR/ExportOptions.plist" 2>/dev/null || echo "")
fi

if [[ -z "$TEAM_ID" || "$TEAM_ID" == "REPLACE_TEAM_ID" || "$TEAM_ID" == "YOUR_TEAM_ID" ]]; then
  echo "ERROR: set ENGRAM_TEAM_ID to your 10-character Apple Developer Team ID."
  echo "Example:"
  echo "  ENGRAM_TEAM_ID=YOUR_TEAM_ID ENGRAM_NOTARY_PROFILE=EngramNotary macos/scripts/build-release.sh"
  exit 1
fi

if [[ "$RELEASE_ARCHS" == *"arm64"* && "$RELEASE_ARCHS" == *"x86_64"* ]]; then
  ARCH_LABEL="${ENGRAM_RELEASE_LABEL:-universal}"
else
  ARCH_LABEL="${ENGRAM_RELEASE_LABEL:-${RELEASE_ARCHS// /-}}"
fi

APP_PATH="$EXPORT_PATH/Engram.app"
SUBMISSION_ZIP="$RELEASE_DIR/Engram-$VERSION-$ARCH_LABEL.notary-submission.zip"
FINAL_ZIP="$RELEASE_DIR/Engram-$VERSION-$ARCH_LABEL.zip"
UNNOTARIZED_ZIP="$RELEASE_DIR/Engram-$VERSION-$ARCH_LABEL.unnotarized.zip"

echo "======================================"
echo " Engram Release Build"
echo "======================================"
echo "Project:        $PROJECT"
echo "Archive:        $ARCHIVE_PATH"
echo "Export:         $EXPORT_PATH"
echo "Release:        $RELEASE_DIR"
echo "Team ID:        $TEAM_ID"
echo "Architectures:  $RELEASE_ARCHS"
echo "Notary profile: ${NOTARY_PROFILE:-<not configured>}"
echo ""

mkdir -p "$BUILD_DIR" "$RELEASE_DIR"
rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH"
rm -f "$EXPORT_OPTIONS" "$SUBMISSION_ZIP" "$FINAL_ZIP" "$UNNOTARIZED_ZIP"

cp "$MACOS_DIR/ExportOptions.plist" "$EXPORT_OPTIONS"
/usr/libexec/PlistBuddy -c "Set teamID $TEAM_ID" "$EXPORT_OPTIONS"

echo "[1/5] Cleaning DerivedData..."
rm -rf ~/Library/Developer/Xcode/DerivedData/Engram-*

echo "[2/5] Regenerating Xcode project..."
cd "$MACOS_DIR"
xcodegen generate

echo "[3/5] Archiving Release build..."
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  "DEVELOPMENT_TEAM=$TEAM_ID" \
  CODE_SIGN_STYLE=Automatic \
  ENABLE_HARDENED_RUNTIME=YES \
  "ARCHS=$RELEASE_ARCHS" \
  ONLY_ACTIVE_ARCH=NO \
  SWIFT_COMPILATION_MODE=singlefile

echo "[4/5] Exporting Developer ID app..."
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -exportPath "$EXPORT_PATH"

echo "[5/5] Verifying signature..."
codesign -dv --verbose=4 "$APP_PATH"
spctl --assess --type execute -vv "$APP_PATH" || true

if [[ -n "$NOTARY_PROFILE" ]]; then
  echo "Creating notarization submission zip..."
  ditto -c -k --keepParent "$APP_PATH" "$SUBMISSION_ZIP"

  echo "Submitting to Apple notarization..."
  xcrun notarytool submit "$SUBMISSION_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

  echo "Stapling notarization ticket..."
  xcrun stapler staple "$APP_PATH"
  xcrun stapler validate "$APP_PATH"

  echo "Creating final distributable zip..."
  ditto -c -k --keepParent "$APP_PATH" "$FINAL_ZIP"
  shasum -a 256 "$FINAL_ZIP" > "$FINAL_ZIP.sha256"

  echo ""
  echo "Release package:"
  echo "  $FINAL_ZIP"
  echo "  $FINAL_ZIP.sha256"
else
  echo "Creating unnotarized zip for local verification..."
  ditto -c -k --keepParent "$APP_PATH" "$UNNOTARIZED_ZIP"
  shasum -a 256 "$UNNOTARIZED_ZIP" > "$UNNOTARIZED_ZIP.sha256"

  echo ""
  echo "Notarization is not configured. Store credentials once, then rerun this script:"
  echo "  xcrun notarytool store-credentials \"EngramNotary\" --apple-id \"APPLE_ID_EMAIL\" --team-id \"$TEAM_ID\" --password \"APP_SPECIFIC_PASSWORD\""
  echo "  ENGRAM_TEAM_ID=$TEAM_ID ENGRAM_NOTARY_PROFILE=EngramNotary macos/scripts/build-release.sh"
  echo ""
  echo "Unnotarized verification package:"
  echo "  $UNNOTARIZED_ZIP"
  echo "  $UNNOTARIZED_ZIP.sha256"
fi

echo ""
echo "Done."
