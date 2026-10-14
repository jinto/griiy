#!/bin/bash
# Builds griiy.app (release) and, with --install, links /usr/local/bin/griiy to it (F-IN-4, M0-3).
# Always hardened runtime, so local runs hit what notarization requires (M4-2). Debug .build/debug/griiy:
# a debugger can't attach to the bundle.
# usage: [VERSION=x.y.z] [GRIIY_SIGN=<identity>] [GRIIY_ARCHS="--arch arm64 --arch x86_64"] scripts/bundle.sh [--install]
# Without GRIIY_SIGN the signature is ad hoc; without GRIIY_ARCHS, this Mac's architecture only.
# -f: GRIIY_ARCHS is split into flags below and must never glob.
set -euf -o pipefail
cd "$(dirname "$0")/.."
version=${VERSION:-0.1.0}
# shellcheck disable=SC2206 # GRIIY_ARCHS is flags, split on purpose
build=(swift build -c release -Xswiftc -warnings-as-errors ${GRIIY_ARCHS:-})
"${build[@]}"
app=.build/griiy.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$("${build[@]}" --show-bin-path)/griiy" "$app/Contents/MacOS/griiy"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>griiy</string>
  <key>CFBundleIdentifier</key><string>dev.griiy.griiy</string>
  <key>CFBundleName</key><string>griiy</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --options runtime ${GRIIY_SIGN:+--timestamp} --sign "${GRIIY_SIGN:--}" "$app"
du -sh "$app"
if [ "${1:-}" = "--install" ]; then
  ln -sf "$PWD/$app/Contents/MacOS/griiy" /usr/local/bin/griiy
  echo "linked /usr/local/bin/griiy"
fi
