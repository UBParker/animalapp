# Animal Voice

iPhone app that records animal vocalizations, tags them, and predicts what new sounds mean per animal. Design: `docs/superpowers/specs/2026-09-15-animal-voice-design.md`.

## Build

Prerequisite: `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` and `brew install xcodegen`.

- `scripts/test-packages.sh`  runs the audio and stats package tests on macOS
- `scripts/build-app.sh`      generates the Xcode project and builds for the simulator
- `scripts/test-app.sh`       runs the app tests on the simulator

To sync with iCloud on a device, set `DEVELOPMENT_TEAM` in `project.yml` to your team id and regenerate.
