#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
SIM="$(xcrun simctl list devices available | grep -m1 -oE 'iPhone [^(]+' | sed 's/ *$//')"
xcodegen generate >/dev/null
xcodebuild -project AnimalVoice.xcodeproj -scheme AnimalVoice \
  -destination "platform=iOS Simulator,name=$SIM" \
  CODE_SIGNING_ALLOWED=NO test 2>&1 | grep -E "error:|Test Case|Executed|TEST" | tail -40
