#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
swift build -c release
mkdir -p dist/Alcove.app/Contents/MacOS
cp .build/release/Alcove dist/Alcove.app/Contents/MacOS/Alcove
cp Resources/Info.plist dist/Alcove.app/Contents/Info.plist
codesign --force --sign - dist/Alcove.app
echo "Built ${PWD}/dist/Alcove.app"
