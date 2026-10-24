#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
swift build -c release
mkdir -p dist/TopNotch.app/Contents/MacOS
mkdir -p dist/TopNotch.app/Contents/Resources
cp .build/release/TopNotch dist/TopNotch.app/Contents/MacOS/TopNotch
cp Resources/Info.plist dist/TopNotch.app/Contents/Info.plist
cp logo.png dist/TopNotch.app/Contents/Resources/TopNotchLogo.png
cp Resources/media-bridge.pl dist/TopNotch.app/Contents/Resources/media-bridge.pl
clang -dynamiclib -O2 -fobjc-arc -arch arm64 -arch x86_64 -mmacosx-version-min=15.0 \
  -framework Foundation -framework AppKit \
  Helper/MediaRemoteBridge.m -o dist/TopNotch.app/Contents/Resources/libTopNotchMedia.dylib
iconset=.build/TopNotch.iconset
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" logo.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
  doubled=$((size * 2))
  sips -z "$doubled" "$doubled" logo.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o dist/TopNotch.app/Contents/Resources/AppIcon.icns
codesign --force --sign - dist/TopNotch.app/Contents/Resources/libTopNotchMedia.dylib
codesign --force --sign - dist/TopNotch.app
echo "Built ${PWD}/dist/TopNotch.app"
