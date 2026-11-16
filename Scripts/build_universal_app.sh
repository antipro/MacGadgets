#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="MacGadgets"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
ZIP_PATH="$DIST_DIR/$APP_NAME-universal.zip"

"$ROOT_DIR/Scripts/build_app.sh" --universal

BIN_PATH="$APP_DIR/Contents/MacOS/$APP_NAME"
if command -v lipo >/dev/null 2>&1; then
    echo "Architectures in $BIN_PATH: $(lipo -archs "$BIN_PATH")"
fi

rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"
echo "Created universal package at: $ZIP_PATH"
