#!/bin/zsh
# Builds Dingo in Release and installs it to /Applications for daily use.
# Debug builds from Xcode run as "Dingo Dev" (com.joshoettinger.dingo.dev) with separate data.
set -euo pipefail
cd "${0:A:h}/.."

xcodegen generate --quiet
xcodebuild -project Dingo.xcodeproj -scheme Dingo -configuration Release \
  -derivedDataPath build/release -quiet build

app="build/release/Build/Products/Release/Dingo.app"
osascript -e 'quit app id "com.joshoettinger.dingo"' 2>/dev/null || true
for _ in {1..50}; do pgrep -qf '^/Applications/Dingo.app/' || break; sleep 0.1; done
if pgrep -qf '^/Applications/Dingo.app/'; then
  echo "Dingo is still running; quit it and run this again." >&2
  exit 1
fi
rm -rf /Applications/Dingo.app
cp -R "$app" /Applications/Dingo.app
echo "Installed /Applications/Dingo.app"
