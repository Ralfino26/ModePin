#!/usr/bin/env bash
# Builds build/ModePin.app (release, ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --arch arm64
bin="$(swift build -c release --arch arm64 --show-bin-path)/ModePin"

app=build/ModePin.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/ModePin"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

codesign --force --sign - --identifier com.ralfh.ModePin "$app"
echo "Built $app"
