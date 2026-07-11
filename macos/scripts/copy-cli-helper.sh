#!/bin/bash
# Bundles the archive operator into Engram.app before the outer app is signed.
set -euo pipefail

SRC="${BUILT_PRODUCTS_DIR}/EngramCLI"
APP="${BUILT_PRODUCTS_DIR}/${FULL_PRODUCT_NAME}"
DEST_DIR="${APP}/Contents/Helpers"
DEST="${DEST_DIR}/EngramCLI"

if [ ! -f "$SRC" ]; then
  echo "[copy-cli-helper] ERROR: $SRC not found — EngramCLI must be built before Engram." >&2
  exit 1
fi

mkdir -p "$DEST_DIR"
ditto "$SRC" "$DEST"

if [ "${CODE_SIGNING_ALLOWED:-}" != "NO" ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
  sign_args=(--force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --options runtime)
  if [ "$EXPANDED_CODE_SIGN_IDENTITY" != "-" ]; then
    sign_args+=(--timestamp)
  else
    sign_args+=(--timestamp=none)
  fi
  if ! codesign "${sign_args[@]}" "$DEST"; then
    echo "[copy-cli-helper] secure timestamp unavailable; retrying helper signing without timestamp" >&2
    codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --options runtime --timestamp=none "$DEST"
  fi
fi
echo "[copy-cli-helper] EngramCLI → $DEST"
