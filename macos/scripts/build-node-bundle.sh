#!/bin/bash
# macos/scripts/build-node-bundle.sh
# Copies compiled daemon.js into the app bundle Resources/node/
set -e

# Xcode strips PATH — ensure node/npm are reachable
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEST="${BUILT_PRODUCTS_DIR}/${CONTENTS_FOLDER_PATH}/Resources/node"

echo "[CodingMemory] Building Node.js daemon..."
cd "$REPO_ROOT"
npm run build

mkdir -p "$DEST"
# Copy the full dist/ tree (daemon.js needs all its sibling modules)
if ! rsync -a --delete dist/ "$DEST/"; then
  echo "[CodingMemory] WARNING: rsync failed, falling back to cp" >&2
  rm -rf "${DEST:?}"/*
  cp -r dist/* "$DEST/"
fi

# Ensure bundle has type:module to avoid Node.js MODULE_TYPELESS_PACKAGE_JSON warning
echo '{"type":"module"}' > "$DEST/package.json"

# Copy node_modules needed by daemon
# Note: for large node_modules, consider using esbundle or pkg in the future
if [ -d node_modules ]; then
  if ! rsync -a --delete node_modules "$DEST/"; then
    echo "[CodingMemory] WARNING: rsync failed for node_modules, falling back to cp" >&2
    rm -rf "$DEST/node_modules"
    cp -r node_modules "$DEST/node_modules"
  fi
fi

echo "[CodingMemory] Node bundle copied to $DEST"

touch "${DERIVED_FILE_DIR}/node-bundle.stamp"
