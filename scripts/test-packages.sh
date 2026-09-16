#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
for p in AnimalVoiceAudio AnimalVoiceStats; do
  echo "== swift test: $p"
  (cd "Packages/$p" && swift test 2>&1 | tail -25)
done
