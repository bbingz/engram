#!/bin/bash
# macos/scripts/build-release.sh
# Full release build pipeline: clean, xcodegen, archive, export, verify, then
# print notarytool/DMG instructions.
#
# Flags:
#   --local-only   Build a NON-DISTRIBUTABLE local-install app when a Developer ID
#                  export is unavailable. The resulting bundle is signed for local
#                  use only (e.g. Apple Development) and CANNOT be notarized. It is
#                  exported to "$EXPORT_PATH/Engram-local-only.app" and clearly
#                  labeled. Without this flag, a failed Developer ID export FAILS.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MACOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

LOCAL_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --local-only) LOCAL_ONLY=1 ;;
    *) echo "build-release: unknown argument: $arg" >&2; exit 2 ;;
  esac
done

SCHEME="Engram"
PROJECT="$MACOS_DIR/Engram.xcodeproj"
ARCHIVE_PATH="$MACOS_DIR/build/Engram.xcarchive"
EXPORT_PATH="$MACOS_DIR/build/EngramExport"

echo "======================================"
echo " Engram Release Build"
echo "======================================"
echo "MACOS_DIR:    $MACOS_DIR"
echo "PROJECT:      $PROJECT"
echo "ARCHIVE_PATH: $ARCHIVE_PATH"
echo "EXPORT_PATH:  $EXPORT_PATH"
echo "LOCAL_ONLY:   $LOCAL_ONLY"
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

# 0. Resolve + auto-inject the build number.
#    MARKETING_VERSION is single-sourced in project.yml; CURRENT_PROJECT_VERSION is
#    auto-bumped here so every release archive carries a unique, non-default build.
MARKETING_VERSION=$(grep -E '^[[:space:]]*MARKETING_VERSION:' "$MACOS_DIR/project.yml" \
  | head -1 | sed -E 's/.*MARKETING_VERSION:[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/')
if [[ -z "$MARKETING_VERSION" ]]; then
  echo "ERROR: could not read MARKETING_VERSION from project.yml" >&2
  exit 1
fi
# Auto build number:
# - ENGRAM_BUILD_NUMBER is authoritative for CI/release automation.
# - Clean git checkouts use commit count for stable official release builds.
# - Dirty local checkouts use a UTC timestamp so repeated local deploys are
#   distinguishable even before the work is committed.
BUILD_NUMBER="${ENGRAM_BUILD_NUMBER:-}"
if [[ -z "$BUILD_NUMBER" ]]; then
  WORKTREE_DIRTY=1
  UNTRACKED_FILES="$(git -C "$MACOS_DIR" ls-files --others --exclude-standard 2>/dev/null || true)"
  if git -C "$MACOS_DIR" diff --quiet --ignore-submodules -- \
    && git -C "$MACOS_DIR" diff --cached --quiet --ignore-submodules -- \
    && [[ -z "$UNTRACKED_FILES" ]]; then
    WORKTREE_DIRTY=0
  fi

  if [[ "$WORKTREE_DIRTY" -eq 0 ]]; then
    BUILD_NUMBER="$(git -C "$MACOS_DIR" rev-list --count HEAD 2>/dev/null || true)"
  fi
fi
if [[ -z "$BUILD_NUMBER" ]]; then
  BUILD_NUMBER="$(date -u +%Y%m%d%H%M%S)"
fi
# Reject the default placeholder build number — releases must carry a real one.
if [[ "$BUILD_NUMBER" == "1" || "$BUILD_NUMBER" == "0" || -z "$BUILD_NUMBER" ]]; then
  echo "ERROR: refusing to release with default/empty build number ('$BUILD_NUMBER')." >&2
  echo "       Set ENGRAM_BUILD_NUMBER or build from a git checkout with history." >&2
  exit 1
fi
echo "Version: $MARKETING_VERSION ($BUILD_NUMBER)"
echo ""

# 1. Clean DerivedData for Engram
echo "[1/5] Cleaning DerivedData..."
rm -rf ~/Library/Developer/Xcode/DerivedData/Engram-*
echo "      Done."
echo ""

# 2. Regenerate Xcode project from project.yml
echo "[2/5] Running xcodegen generate..."
cd "$MACOS_DIR"
xcodegen generate
echo "      Done."
echo ""

# 3. Archive (inject the resolved version)
echo "[3/5] Archiving..."
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  CODE_SIGN_STYLE=Automatic \
  MARKETING_VERSION="$MARKETING_VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
echo "      Archive created at: $ARCHIVE_PATH"
echo ""

# Assert the archived app carries the injected, non-default build number.
ARCHIVED_APP="$ARCHIVE_PATH/Products/Applications/Engram.app"
if [[ ! -d "$ARCHIVED_APP" ]]; then
  echo "ERROR: archive did not produce $ARCHIVED_APP" >&2
  exit 1
fi
ARCHIVED_BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$ARCHIVED_APP/Contents/Info.plist" 2>/dev/null || echo "")"
if [[ "$ARCHIVED_BUILD" != "$BUILD_NUMBER" ]]; then
  echo "ERROR: archived CFBundleVersion '$ARCHIVED_BUILD' != injected '$BUILD_NUMBER'." >&2
  echo "       Version single-sourcing is broken — aborting before export." >&2
  exit 1
fi

# 4. Export archive (Developer ID)
echo "[4/5] Exporting archive (developer-id)..."
EXPORT_LOG="$MACOS_DIR/build/export.log"
mkdir -p "$(dirname "$EXPORT_LOG")"
rm -rf "$EXPORT_PATH"
set -o pipefail
if xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportOptionsPlist "$MACOS_DIR/ExportOptions.plist" \
  -exportPath "$EXPORT_PATH" 2>&1 | tee "$EXPORT_LOG"; then
  :
else
  # Developer ID export failed. This is FATAL by default: shipping the
  # Apple-Development-signed app from the archive produces a NON-NOTARIZABLE
  # binary while pretending the release succeeded (REL-C1). Fail loudly.
  echo "" >&2
  echo "ERROR: Developer ID export failed (see $EXPORT_LOG)." >&2
  echo "       Common cause: no 'Developer ID Application' certificate / profile" >&2
  echo "       available for team $TEAM_ID." >&2
  if [[ "$LOCAL_ONLY" -ne 1 ]]; then
    echo "" >&2
    echo "       A Developer ID export is required for a distributable, notarizable" >&2
    echo "       build. Refusing to fall back to a non-distributable signed app." >&2
    echo "       For a local-install-only convenience build, re-run with --local-only." >&2
    exit 1
  fi

  # --local-only: produce an explicitly non-distributable bundle from the archive.
  echo "" >&2
  echo "WARNING: --local-only set. Producing a NON-DISTRIBUTABLE local-install app." >&2
  echo "         This bundle is NOT Developer-ID signed and CANNOT be notarized." >&2
  echo "         Do not distribute it." >&2
  mkdir -p "$EXPORT_PATH"
  ditto "$ARCHIVED_APP" "$EXPORT_PATH/Engram-local-only.app"
  echo ""
  echo "Local-only app: $EXPORT_PATH/Engram-local-only.app (non-distributable)"
  # Identity-independent hygiene + structure checks still apply.
  "$SCRIPT_DIR/release-verify.sh" "$EXPORT_PATH/Engram-local-only.app" --adhoc --expected-build "$BUILD_NUMBER"
  echo ""
  echo "build-release: local-only build complete (NOT for distribution)."
  exit 0
fi

if [[ ! -d "$EXPORT_PATH/Engram.app" ]]; then
  echo "" >&2
  echo "ERROR: Export did not produce $EXPORT_PATH/Engram.app" >&2
  echo "" >&2
  exit 1
fi
echo "      Export created at: $EXPORT_PATH"
echo ""

# 5. Verify the exported, distributable app (hygiene + Hardened Runtime + Developer ID + timestamp).
echo "[5/5] Verifying exported app..."
"$SCRIPT_DIR/release-verify.sh" "$EXPORT_PATH/Engram.app" --expected-build "$BUILD_NUMBER"
echo ""

echo "======================================"
echo " Build complete!"
echo " Exported app: $EXPORT_PATH/Engram.app"
echo " Version:      $MARKETING_VERSION ($BUILD_NUMBER)"
echo "======================================"
echo ""

echo "--------------------------------------"
echo " Next steps (run manually):"
echo "--------------------------------------"
echo ""
echo "# 1. One-time setup: store notarization credentials in Keychain:"
echo "xcrun notarytool store-credentials \"engram-notary\""
echo ""
echo "# 2. Notarize the app using the Keychain profile:"
echo "ditto -c -k --keepParent \"$EXPORT_PATH/Engram.app\" \\"
echo "    \"$EXPORT_PATH/Engram.zip\""
echo "xcrun notarytool submit \"$EXPORT_PATH/Engram.zip\" \\"
echo "  --keychain-profile \"engram-notary\" \\"
echo "  --wait"
echo ""
echo "# 3. Staple and verify the notarization ticket:"
echo "xcrun stapler staple \"$EXPORT_PATH/Engram.app\""
echo "$SCRIPT_DIR/release-verify.sh \"$EXPORT_PATH/Engram.app\" \\"
echo "  --expected-build \"$BUILD_NUMBER\" --require-notarization"
echo ""
echo "# 4. Install locally:"
echo "$SCRIPT_DIR/deploy-local.sh \"$EXPORT_PATH/Engram.app\""
echo ""
echo "# 5. Create a DMG for distribution (requires: brew install create-dmg):"
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
