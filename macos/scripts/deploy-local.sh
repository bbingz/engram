#!/bin/bash
# macos/scripts/deploy-local.sh
# Installs a freshly built Engram.app into /Applications.
#   1. Quit the running app (cp -R / ditto silently skip a running binary otherwise).
#   2. rm -rf the existing /Applications/Engram.app.
#   3. ditto the export into place.
#   4. Verify the installed CFBundleVersion matches the just-built one.
#
# Usage: deploy-local.sh /path/to/Engram.app
set -euo pipefail

SRC_APP="${1:-}"
DEST_APP="/Applications/Engram.app"

if [ -z "$SRC_APP" ] || [ ! -d "$SRC_APP" ]; then
  echo "deploy-local: source app bundle not found: '$SRC_APP'" >&2
  echo "usage: deploy-local.sh /path/to/Engram.app" >&2
  exit 1
fi

SRC_PLIST="$SRC_APP/Contents/Info.plist"
SRC_BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$SRC_PLIST" 2>/dev/null || echo "")"
if [ -z "$SRC_BUILD" ]; then
  echo "deploy-local: could not read CFBundleVersion from source app" >&2
  exit 1
fi
echo "deploy-local: source CFBundleVersion=$SRC_BUILD"

# 1. Quit the running app.
echo "deploy-local: quitting running Engram (if any)..."
osascript -e 'tell application "Engram" to quit' >/dev/null 2>&1 || true
# Fall back to a hard kill if it is still alive.
pkill -x Engram >/dev/null 2>&1 || true
# Give the process a moment to release its files.
for _ in 1 2 3 4 5; do
  pgrep -x Engram >/dev/null 2>&1 || break
  /bin/sleep 1
done

# 2. Remove the existing install.
echo "deploy-local: removing $DEST_APP..."
rm -rf "$DEST_APP"

# 3. Install via ditto (preserves signatures/xattrs).
echo "deploy-local: installing into $DEST_APP..."
ditto "$SRC_APP" "$DEST_APP"

# 4. Verify the installed build matches.
DEST_BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$DEST_APP/Contents/Info.plist" 2>/dev/null || echo "")"
if [ "$DEST_BUILD" != "$SRC_BUILD" ]; then
  echo "deploy-local: FAIL: installed CFBundleVersion '$DEST_BUILD' != built '$SRC_BUILD'" >&2
  exit 1
fi
echo "deploy-local: installed CFBundleVersion=$DEST_BUILD (matches build)"
echo "deploy-local: done."
