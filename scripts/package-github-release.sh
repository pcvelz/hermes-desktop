#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="$ROOT_DIR/dist/HermesDesktop.app"
ZIP_PATH="$ROOT_DIR/dist/HermesDesktop.app.zip"
SHA256_PATH="$ZIP_PATH.sha256"

"$ROOT_DIR/scripts/build-macos-app.sh"

rm -f "$ZIP_PATH"
xattr -cr "$APP_PATH" 2>/dev/null || true
ditto -c -k --norsrc --keepParent "$APP_PATH" "$ZIP_PATH"
(
    cd "$ROOT_DIR"
    shasum -a 256 "dist/HermesDesktop.app.zip" > "$SHA256_PATH"
)

echo
echo "Release archive created:"
echo "  $ZIP_PATH"
echo "Checksum:"
echo "  $SHA256_PATH"
