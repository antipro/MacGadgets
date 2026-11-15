#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_BIN="$ROOT_DIR/.build/MacGadgetsTests"
mkdir -p "$ROOT_DIR/.build"

swiftc \
    -parse-as-library \
    -framework Foundation \
    -framework IOKit \
    -framework CoreGraphics \
    -framework ApplicationServices \
    "$ROOT_DIR/Sources/MacGadgets/Support/DurationFormatter.swift" \
    "$ROOT_DIR/Sources/MacGadgets/Core/PowerAssertion.swift" \
    "$ROOT_DIR/Sources/MacGadgets/Core/ScrollEventTap.swift" \
    "$ROOT_DIR/Sources/MacGadgets/Core/MTPProtocol.swift" \
    "$ROOT_DIR/Sources/MacGadgets/Core/MTPVirtualFileSystem.swift" \
    "$ROOT_DIR/Sources/MacGadgets/Core/NFSv3Server.swift" \
    "$ROOT_DIR/Tests/run_tests.swift" \
    -o "$OUT_BIN"

"$OUT_BIN"
