#!/bin/bash
# macos/scripts/build-release.sh
# Full release build pipeline: clean, xcodegen, archive, export, then print notarytool/DMG instructions.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MACOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

SCHEME="Engram"
PROJECT="$MACOS_DIR/Engram.xcodeproj"
ARCHIVE_PATH="$MACOS_DIR/build/Engram.xcarchive"
EXPORT_PATH="$MACOS_DIR/build/EngramExport"

echo "======================================"
echo " CodingMemory Release Build"
echo "======================================"
echo "MACOS_DIR:    $MACOS_DIR"
echo "PROJECT:      $PROJECT"
echo "ARCHIVE_PATH: $ARCHIVE_PATH"
echo "EXPORT_PATH:  $EXPORT_PATH"
echo ""

# Read team ID from ExportOptions.plist and validate
TEAM_ID=$(/usr/libexec/PlistBuddy -c "Print teamID" "$MACOS_DIR/ExportOptions.plist" 2>/dev/null || echo "")
if [[ -z "$TEAM_ID" || "$TEAM_ID" == "REPLACE_TEAM_ID" ]]; then
  echo ""
  echo "ERROR: You must set your Apple Developer Team ID in macos/ExportOptions.plist"
  echo "       Replace 'REPLACE_TEAM_ID' with your 10-character Team ID"
  echo "       Find it at: https://developer.apple.com/account → Membership → Team ID"
  echo ""
  exit 1
fi

# 1. Clean DerivedData for Engram
echo "[1/4] Cleaning DerivedData..."
rm -rf ~/Library/Developer/Xcode/DerivedData/Engram-*
echo "      Done."
echo ""

# 2. Regenerate Xcode project from project.yml
echo "[2/4] Running xcodegen generate..."
cd "$MACOS_DIR"
xcodegen generate
echo "      Done."
echo ""

# 3. Archive
echo "[3/4] Archiving..."
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  CODE_SIGN_STYLE=Automatic
echo "      Archive created at: $ARCHIVE_PATH"
echo ""

# 4. Export archive
echo "[4/4] Exporting archive..."
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportOptionsPlist "$MACOS_DIR/ExportOptions.plist" \
  -exportPath "$EXPORT_PATH"
echo "      Export created at: $EXPORT_PATH"
echo ""

echo "======================================"
echo " Build complete!"
echo " Exported app: $EXPORT_PATH/Engram.app"
echo "======================================"
echo ""

echo "--------------------------------------"
echo " Next steps (run manually):"
echo "--------------------------------------"
echo ""
echo "# 1. Notarize the app:"
echo "ditto -c -k --keepParent \"$EXPORT_PATH/Engram.app\" \\"
echo "    \"$EXPORT_PATH/Engram.zip\""
echo "xcrun notarytool submit \"$EXPORT_PATH/Engram.zip\" \\"
echo "  --apple-id \"YOUR_APPLE_ID\" \\"
echo "  --team-id \"YOUR_TEAM_ID\" \\"
echo "  --password \"YOUR_APP_SPECIFIC_PASSWORD\" \\"
echo "  --wait"
echo ""
echo "# 2. Staple the notarization ticket:"
echo "xcrun stapler staple \"$EXPORT_PATH/Engram.app\""
echo ""
echo "# 3. Create a DMG for distribution (requires: brew install create-dmg):"
echo "create-dmg \\"
echo "  --volname \"Engram\" \\"
echo "  --window-pos 200 120 \\"
echo "  --window-size 800 400 \\"
echo "  --icon-size 100 \\"
echo "  --icon \"Engram.app\" 200 190 \\"
echo "  --hide-extension \"Engram.app\" \\"
echo "  --app-drop-link 600 185 \\"
echo "  \"Engram.dmg\" \\"
echo "  \"$EXPORT_PATH/\""
echo ""
