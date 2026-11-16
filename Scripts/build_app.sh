#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="MacGadgets"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

cd "$ROOT_DIR"

UNIVERSAL_BUILD=0
if [[ "${1:-}" == "--universal" || "${UNIVERSAL:-0}" == "1" ]]; then
    UNIVERSAL_BUILD=1
fi

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

if [[ "$UNIVERSAL_BUILD" == "1" ]]; then
    echo "Building $APP_NAME (release, universal: arm64 + x86_64)..."
    swift build -c release --arch arm64 --product "$APP_NAME"
    ARM64_BIN="$(swift build -c release --arch arm64 --show-bin-path)/$APP_NAME"

    swift build -c release --arch x86_64 --product "$APP_NAME"
    X86_64_BIN="$(swift build -c release --arch x86_64 --show-bin-path)/$APP_NAME"

    lipo -create "$ARM64_BIN" "$X86_64_BIN" -output "$MACOS_DIR/$APP_NAME"
else
    echo "Building $APP_NAME (release)..."
    swift build -c release --product "$APP_NAME"
    BIN_PATH="$(swift build -c release --show-bin-path)/$APP_NAME"
    cp "$BIN_PATH" "$MACOS_DIR/$APP_NAME"
fi

chmod +x "$MACOS_DIR/$APP_NAME"
cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
if [[ -f "$ROOT_DIR/Resources/AppIcon.icns" ]]; then
    cp "$ROOT_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi
for lproj in "$ROOT_DIR/Resources/"*.lproj; do
    if [[ -d "$lproj" ]]; then
        cp -R "$lproj" "$RESOURCES_DIR/"
    fi
done
printf 'APPL????' > "$CONTENTS_DIR/PkgInfo"

if command -v codesign >/dev/null 2>&1; then
    IDENTITY="${CODESIGN_IDENTITY:-}"
    if [[ -z "$IDENTITY" ]]; then
        IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -n 1 || true)"
    fi
    if [[ -z "$IDENTITY" ]]; then
        IDENTITY="-"
    fi
    echo "Signing with: $IDENTITY"
    codesign --force --deep --sign "$IDENTITY" "$APP_DIR"
fi

echo "Built bundle at: $APP_DIR"
