#!/usr/bin/env bash
# Build, install, launch in the simulator, and screenshot to build/screenshot.png
set -euo pipefail
cd "$(dirname "$0")/.."
SIM="$(xcrun simctl list devices available | grep -m1 -oE 'iPhone [^(]+' | sed 's/ *$//')"
scripts/build-app.sh
xcrun simctl boot "$SIM" 2>/dev/null || true
xcrun simctl bootstatus "$SIM" -b >/dev/null
open -a Simulator
APP="$(find ~/Library/Developer/Xcode/DerivedData -maxdepth 6 -path '*Build/Products/Debug-iphonesimulator/AnimalTracker.app' -print -quit)"
if [ -z "$APP" ]; then
  echo "No built AnimalTracker.app under ~/Library/Developer/Xcode/DerivedData. Run scripts/build-app.sh first." >&2
  exit 1
fi
xcrun simctl install "$SIM" "$APP"
xcrun simctl launch "$SIM" com.ashlab.AnimalTracker
sleep 4
mkdir -p build
xcrun simctl io "$SIM" screenshot build/screenshot.png
echo "screenshot: build/screenshot.png"
