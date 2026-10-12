#!/bin/bash
# Builds griiy.app (release) and, with --install, links /usr/local/bin/griiy to it (F-IN-4, M0-3).
# Signing is ad hoc; Developer ID signing, notarization and universal builds are M4-2.
# usage: scripts/bundle.sh [--install]
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release -Xswiftc -warnings-as-errors
app=.build/griiy.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp .build/release/griiy "$app/Contents/MacOS/griiy"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>griiy</string>
  <key>CFBundleIdentifier</key><string>dev.griiy.griiy</string>
  <key>CFBundleName</key><string>griiy</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app"
du -sh "$app"
if [ "${1:-}" = "--install" ]; then
  ln -sf "$PWD/$app/Contents/MacOS/griiy" /usr/local/bin/griiy
  echo "linked /usr/local/bin/griiy"
fi
