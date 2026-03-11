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
rsync -a --delete dist/ "$DEST/" 2>/dev/null || cp -r dist/* "$DEST/"

# Copy node_modules needed by daemon
# Note: for large node_modules, consider using esbundle or pkg in the future
if [ -d node_modules ]; then
  rsync -a --delete node_modules "$DEST/" 2>/dev/null || cp -r node_modules "$DEST/node_modules"
fi

echo "[CodingMemory] Node bundle copied to $DEST"

touch "${DERIVED_FILE_DIR}/node-bundle.stamp"
