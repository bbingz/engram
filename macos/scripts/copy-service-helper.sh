#!/bin/bash
# Bundles the EngramService helper tool into Engram.app/Contents/Helpers/EngramService.
# Runs before the app's final codesign step so the outer seal covers the helper.
set -euo pipefail

SRC="${BUILT_PRODUCTS_DIR}/EngramService"
APP="${BUILT_PRODUCTS_DIR}/${FULL_PRODUCT_NAME}"
DEST_DIR="${APP}/Contents/Helpers"
DEST="${DEST_DIR}/EngramService"
FRAMEWORKS_DIR="${APP}/Contents/Frameworks"

if [ ! -f "$SRC" ]; then
  echo "[copy-service-helper] ERROR: $SRC not found — EngramService must be built before Engram." >&2
  exit 1
fi

mkdir -p "$DEST_DIR"
ditto "$SRC" "$DEST"
if [ "${CODE_SIGNING_ALLOWED:-}" != "NO" ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
  codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --options runtime --timestamp=none "$DEST"
fi
mkdir -p "$FRAMEWORKS_DIR"
for framework in EngramServiceCore.framework EngramCoreRead.framework EngramCoreWrite.framework; do
  framework_src="${BUILT_PRODUCTS_DIR}/${framework}"
  if [ ! -d "$framework_src" ]; then
    echo "[copy-service-helper] ERROR: $framework_src not found — EngramService framework dependencies must be built before Engram." >&2
    exit 1
  fi
  framework_dest="${FRAMEWORKS_DIR}/${framework}"
  ditto "$framework_src" "$framework_dest"
  if [ "${CODE_SIGNING_ALLOWED:-}" != "NO" ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
    codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --options runtime --timestamp=none "$framework_dest"
  fi
done
if [ "${CODE_SIGNING_ALLOWED:-}" != "NO" ] \
  && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ] \
  && [ ! -d "${APP}/Contents/PlugIns" ]; then
  debug_dylib="${APP}/Contents/MacOS/Engram.debug.dylib"
  if [ -f "$debug_dylib" ]; then
    codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --options runtime --timestamp=none "$debug_dylib"
  fi
  entitlements_args=()
  entitlements_path="${CODE_SIGN_ENTITLEMENTS:-}"
  if [ -n "$entitlements_path" ] && [ -f "${SRCROOT}/${entitlements_path}" ]; then
    entitlements_args=(--entitlements "${SRCROOT}/${entitlements_path}")
  fi
  codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" "${entitlements_args[@]}" --options runtime --timestamp=none "$APP"
fi
echo "[copy-service-helper] EngramService → $DEST"
