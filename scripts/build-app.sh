#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache"
if [[ ! -f Assets/AppIcon.icns || Assets/AppIcon.svg -nt Assets/AppIcon.icns || scripts/render-icon.swift -nt Assets/AppIcon.icns || scripts/build-icon.sh -nt Assets/AppIcon.icns ]]; then
    bash scripts/build-icon.sh
fi
swift build -c release --disable-sandbox
BIN_DIR="$(swift build -c release --show-bin-path --disable-sandbox)"
APP="$PWD/dist/Session Scout.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/SessionScout" "$APP/Contents/MacOS/SessionScout"
cp "Sources/SessionMonitor/Resources/config.json" "$APP/Contents/Resources/config.json"
cp "Sources/SessionScout/Resources/quit.svg" "$APP/Contents/Resources/quit.svg"
cp "Sources/SessionScout/Resources/scout.svg" "$APP/Contents/Resources/scout.svg"
cp "Sources/SessionScout/Resources/settings.svg" "$APP/Contents/Resources/settings.svg"
cp "Sources/SessionScout/Resources/action-required.wav" "$APP/Contents/Resources/action-required.wav"
cp "Sources/SessionScout/Resources/turn-finished.wav" "$APP/Contents/Resources/turn-finished.wav"
cp "Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleExecutable</key><string>SessionScout</string>
    <key>CFBundleIdentifier</key><string>com.codexwatcher.app</string>
    <key>CFBundleName</key><string>Session Scout</string>
    <key>CFBundleDisplayName</key><string>Session Scout</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
touch "$APP"
echo "Built $APP"
