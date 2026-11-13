#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ICONSET="$PWD/.build/AppIcon.iconset"
mkdir -p "$ICONSET"
swift -module-cache-path "$PWD/.build/clang-module-cache" scripts/render-icon.swift Assets/AppIcon.svg "$ICONSET"
iconutil --convert icns --output Assets/AppIcon.icns "$ICONSET"
cp "$ICONSET/icon_512x512@2x.png" Assets/AppIcon.png
