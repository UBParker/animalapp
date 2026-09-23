#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
SIM="$(xcrun simctl list devices available | grep -m1 -oE 'iPhone [^(]+' | sed 's/ *$//')"
xcodegen generate >/dev/null
mkdir -p build
# Keep xcodebuild's own status: a grep over the log says nothing about whether the tests passed.
set +e
xcodebuild -project AnimalTracker.xcodeproj -scheme AnimalTracker \
  -destination "platform=iOS Simulator,name=$SIM" \
  test > build/xcodebuild.log 2>&1
status=$?
set -e
grep -E "error:|Test Case|Executed|TEST" build/xcodebuild.log | tail -40
exit $status
