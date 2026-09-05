#!/bin/bash
# macos/scripts/deploy-local.sh
# Installs a freshly built Engram.app into /Applications.
#   1. Quit the running app (cp -R / ditto silently skip a running binary otherwise).
#   2. Verify the source bundle's shipped structure and hygiene.
#   3. Wait for all bundled executables to exit.
#   4. rm -rf the existing /Applications/Engram.app.
#   5. ditto the export into place and verify its CFBundleVersion.
#
# Usage: deploy-local.sh /path/to/Engram.app
set -euo pipefail

SRC_APP="${1:-}"
DEST_APP="/Applications/Engram.app"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

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

# Refuse to replace an installed app with a source bundle that is missing a
# helper/framework or contains a forbidden Node product artifact.
"$SCRIPT_DIR/release-verify.sh" "$SRC_APP" --hygiene-only

# 1. Quit the running app.
echo "deploy-local: quitting running Engram (if any)..."
osascript -e 'tell application "Engram" to quit' >/dev/null 2>&1 || true
# Ask the app and service to terminate cooperatively. MCP clients can respawn
# while an editor is open, so their termination is best-effort and never blocks
# replacement of the app bundle.
BLOCKING_PROCESS_NAMES=(Engram EngramService)
for process_name in "${BLOCKING_PROCESS_NAMES[@]}"; do
  pkill -TERM -x "$process_name" >/dev/null 2>&1 || true
done
pkill -TERM -x EngramMCP >/dev/null 2>&1 || true
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  any_running=0
  pkill -TERM -x EngramMCP >/dev/null 2>&1 || true
  for process_name in "${BLOCKING_PROCESS_NAMES[@]}"; do
    pkill -TERM -x "$process_name" >/dev/null 2>&1 || true
    if pgrep -x "$process_name" >/dev/null 2>&1; then
      any_running=1
    fi
  done
  [ "$any_running" -eq 0 ] && break
  /bin/sleep 1
done
for process_name in "${BLOCKING_PROCESS_NAMES[@]}"; do
  if pgrep -x "$process_name" >/dev/null 2>&1; then
    echo "deploy-local: FAIL: $process_name is still running; existing app was not removed" >&2
    exit 1
  fi
done

# Remove the existing install only after the complete process-exit gate passes.
echo "deploy-local: removing $DEST_APP..."
rm -rf "$DEST_APP"

# 3. Install via ditto (preserves signatures/xattrs).
echo "deploy-local: installing into $DEST_APP..."
ditto "$SRC_APP" "$DEST_APP"
pkill -TERM -x EngramMCP >/dev/null 2>&1 || true

# 4. Verify the installed build matches.
DEST_BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$DEST_APP/Contents/Info.plist" 2>/dev/null || echo "")"
if [ "$DEST_BUILD" != "$SRC_BUILD" ]; then
  echo "deploy-local: FAIL: installed CFBundleVersion '$DEST_BUILD' != built '$SRC_BUILD'" >&2
  exit 1
fi
echo "deploy-local: installed CFBundleVersion=$DEST_BUILD (matches build)"
echo "deploy-local: done."
