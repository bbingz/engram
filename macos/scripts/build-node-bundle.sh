#!/bin/bash
# macos/scripts/build-node-bundle.sh
# Copies compiled daemon.js into the app bundle Resources/node/
set -e

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEST="${BUILT_PRODUCTS_DIR}/${CONTENTS_FOLDER_PATH}/Resources/node"

echo "[CodingMemory] Building Node.js daemon..."
cd "$REPO_ROOT"
npm run build

mkdir -p "$DEST"
cp dist/daemon.js "$DEST/daemon.js"

# Copy node_modules needed by daemon
# Note: for large node_modules, consider using esbundle or pkg in the future
if [ -d node_modules ]; then
  rsync -a --delete node_modules "$DEST/" 2>/dev/null || cp -r node_modules "$DEST/node_modules"
fi

echo "[CodingMemory] Node bundle copied to $DEST"

touch "${DERIVED_FILE_DIR}/node-bundle.stamp"
