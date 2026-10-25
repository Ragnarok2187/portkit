#!/bin/bash
# Builds a universal (Apple Silicon + Intel) PortKit.app into ./dist.
#   VERSION=1.2.0 ./build.sh        set the version shown in Finder
#   REPO=you/portkit ./build.sh     GitHub repo opened by Help ▸ PortKit on GitHub
#   ARCHS="arm64" ./build.sh        build for one architecture only (faster)
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-0.1.0}"
REPO="${REPO:-Ragnarok2187/portkit}"
ARCHS="${ARCHS:-arm64 x86_64}"

ARCH_FLAGS=()
for a in $ARCHS; do ARCH_FLAGS+=(--arch "$a"); done

swift build -c release "${ARCH_FLAGS[@]}"
BIN_DIR="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)"

APP="dist/PortKit.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/PortKit" "$APP/Contents/MacOS/PortKit"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/wow64cpu-*-rosetta.dll "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>PortKit</string>
  <key>CFBundleIdentifier</key><string>io.github.portkit</string>
  <key>CFBundleName</key><string>PortKit</string>
  <key>CFBundleDisplayName</key><string>PortKit</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
  <key>PKRepository</key><string>${REPO}</string>
</dict>
</plist>
PLIST

# Ad-hoc signature: required for Apple Silicon. Not notarized (see README for first launch).
codesign --force --sign - "$APP"
echo "Built $APP ($VERSION, $(lipo -archs "$APP/Contents/MacOS/PortKit"))"
