#!/bin/zsh
# Build Notesy and assemble the .app bundle in dist/.
# Usage: scripts/build-app.sh [debug|release]
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/Notesy.app"

cd "$ROOT"
swift build -c "$CONFIG"
BIN="$ROOT/.build/$CONFIG/Notesy"

pkill -x Notesy 2>/dev/null || true

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Notesy"
cp "$ROOT/Notesy.icns" "$APP/Contents/Resources/AppIcon.icns"
# Write Info.plist with icon reference
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Notesy</string>
    <key>CFBundleIdentifier</key><string>com.notesy.app</string>
    <key>CFBundleName</key><string>Notesy</string>
    <key>CFBundleDisplayName</key><string>Notesy</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null
echo "built: $APP"
