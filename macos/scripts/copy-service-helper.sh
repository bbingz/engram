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

sign_enabled() {
  [ "${CODE_SIGNING_ALLOWED:-}" != "NO" ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]
}

# Build the codesign argument list once. Hardened Runtime (--options runtime) is
# required for notarization; a secure timestamp (--timestamp) is required too, but
# only obtainable with a real identity. Ad-hoc signing ("-") falls back to no timestamp.
# Only reference EXPANDED_CODE_SIGN_IDENTITY when signing is active — Xcode leaves
# it unset for CODE_SIGNING_ALLOWED=NO builds and `set -u` would otherwise abort.
sign_args=()
if sign_enabled; then
  sign_args=(--force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --options runtime)
  if [ "$EXPANDED_CODE_SIGN_IDENTITY" != "-" ]; then
    sign_args+=(--timestamp)
  else
    sign_args+=(--timestamp=none)
  fi
fi

sign_path() {
  local path="$1"
  if ! codesign "${sign_args[@]}" "$path"; then
    echo "[copy-service-helper] secure timestamp unavailable; retrying signing without timestamp: $path" >&2
    codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --options runtime --timestamp=none "$path"
  fi
}

mkdir -p "$DEST_DIR"
ditto "$SRC" "$DEST"
if sign_enabled; then
  sign_path "$DEST"
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
  if sign_enabled; then
    sign_path "$framework_dest"
  fi
done

# GRDB is the shared GRDB-dynamic SPM product (one dynamic framework, ONE copy
# per process) instead of being statically embedded into each of the three
# frameworks above. Three static copies put three GRDB.SchedulingWatchdog
# registries in the EngramService process, which crashed with a false
# "Database was not used on the correct thread" SIGTRAP. The dynamic product is
# emitted under PackageFrameworks/; bundle it next to the others so the helper
# and the app resolve the single shared copy through @rpath/../Frameworks.
# Plain `xcodebuild build` emits the SPM dynamic product under PackageFrameworks/;
# `xcodebuild archive` emits it directly in BUILT_PRODUCTS_DIR. Accept both.
grdb_src=""
for grdb_cand in \
  "${BUILT_PRODUCTS_DIR}/PackageFrameworks/GRDB-dynamic.framework" \
  "${BUILT_PRODUCTS_DIR}/GRDB-dynamic.framework"; do
  if [ -d "$grdb_cand" ]; then
    grdb_src="$grdb_cand"
    break
  fi
done
if [ -z "$grdb_src" ]; then
  echo "[copy-service-helper] ERROR: GRDB-dynamic.framework not found in BUILT_PRODUCTS_DIR (checked PackageFrameworks/ and root) — GRDB-dynamic must be built before Engram." >&2
  exit 1
fi
grdb_dest="${FRAMEWORKS_DIR}/GRDB-dynamic.framework"
ditto "$grdb_src" "$grdb_dest"
if sign_enabled; then
  sign_path "$grdb_dest"
fi

if sign_enabled && [ ! -d "${APP}/Contents/PlugIns" ]; then
  debug_dylib="${APP}/Contents/MacOS/Engram.debug.dylib"
  if [ -f "$debug_dylib" ]; then
    sign_path "$debug_dylib"
  fi
  preview_dylib="${APP}/Contents/MacOS/__preview.dylib"
  if [ -f "$preview_dylib" ]; then
    codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --timestamp=none "$preview_dylib"
  fi
  entitlements_args=()
  entitlements_path="${CODE_SIGN_ENTITLEMENTS:-}"
  if [ -n "$entitlements_path" ] && [ -f "${SRCROOT}/${entitlements_path}" ]; then
    entitlements_args=(--entitlements "${SRCROOT}/${entitlements_path}")
  fi
  if ! codesign "${sign_args[@]}" "${entitlements_args[@]}" "$APP"; then
    echo "[copy-service-helper] secure timestamp unavailable; retrying app signing without timestamp" >&2
    codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --options runtime --timestamp=none "${entitlements_args[@]}" "$APP"
  fi
fi
echo "[copy-service-helper] EngramService → $DEST"
