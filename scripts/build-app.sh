#!/bin/bash
# Builds for the current Mac; CLIPLINE_ARCHS="arm64 x86_64" makes a universal app.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${CLIPLINE_APP_PATH:-build/Clipline-0.1.15.app}"
mkdir -p .build/module-cache build
source scripts/toolchain-env.sh
ARCHS="${CLIPLINE_ARCHS:-$(uname -m)}"
BINARIES=()
for arch in $ARCHS; do
  swiftc -O -whole-module-optimization "${CLIPLINE_SWIFT_FLAGS[@]}" \
    -target "$arch-apple-macosx14.0" Sources/Tendedero/*.swift -o ".build/Clipline-$arch"
  BINARIES+=(".build/Clipline-$arch")
done
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${BINARIES[@]}" -output "$APP/Contents/MacOS/Clipline"
swiftc "${CLIPLINE_SWIFT_FLAGS[@]}" -parse-as-library Sources/Tendedero/CliplineIcon.swift scripts/make-clipline-icon.swift -o .build/icon-generator
.build/icon-generator .build/icon.png build/menu-icon-preview.png
cp .build/icon.png build/clipline-icon-preview.png
ICONSET=".build/Clipline.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" .build/icon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z "$((size*2))" "$((size*2))" .build/icon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Clipline.icns"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
cp -R Resources/Localizations/*.lproj "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Clipline</string>
  <key>CFBundleDisplayName</key><string>Clipline</string>
  <key>CFBundleIdentifier</key><string>local.clipline.app</string>
  <key>CFBundleExecutable</key><string>Clipline</string>
  <key>CFBundleIconFile</key><string>Clipline</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.15</string>
  <key>CFBundleVersion</key><string>16</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string><string>zh-Hant</string><string>es</string></array>
  <key>NSDesktopFolderUsageDescription</key>
  <string>Clipline watches for new screenshot files to hang on the line.</string>
  <key>NSDocumentsFolderUsageDescription</key>
  <string>Clipline reads screenshots and recordings from the save folder you choose.</string>
  <key>NSDownloadsFolderUsageDescription</key>
  <string>Clipline reads screenshots and recordings from the save folder you choose.</string>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP"
echo "Built $APP ($ARCHS)"
