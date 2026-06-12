#!/bin/zsh
# Build PitStop.app (menu bar app) and install it into /Applications.
# The bundle is ad-hoc signed, but that no longer matters for keychain
# access: PitStop goes through /usr/bin/security (same as Claude Code),
# so the keychain grant rides the stable Apple-signed CLI and survives
# rebuilds. No prompts after the one-time "Always Allow" per item.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="/Applications/PitStop.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/PitStop "$APP/Contents/MacOS/PitStop"
cp Resources/PitStop-Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"

echo "Installed $APP"
