#!/bin/bash
# macos/scripts/copy-mcp-helper.sh
# Bundles the EngramMCP helper tool into Engram.app/Contents/Helpers/EngramMCP.
# Users point .claude/mcp.json at /Applications/Engram.app/Contents/Helpers/EngramMCP.
# Runs BEFORE Xcode's automatic codesign step, so the outer seal will cover the helper.
set -euo pipefail

SRC="${BUILT_PRODUCTS_DIR}/EngramMCP"
APP="${BUILT_PRODUCTS_DIR}/${FULL_PRODUCT_NAME}"
DEST_DIR="${APP}/Contents/Helpers"
DEST="${DEST_DIR}/EngramMCP"

if [ ! -f "$SRC" ]; then
  echo "[copy-mcp-helper] ERROR: $SRC not found — EngramMCP must be built before Engram." >&2
  exit 1
fi

mkdir -p "$DEST_DIR"
ditto "$SRC" "$DEST"
if [ "${CODE_SIGNING_ALLOWED:-}" != "NO" ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
  codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --options runtime --timestamp=none "$DEST"
fi
echo "[copy-mcp-helper] EngramMCP → $DEST"
