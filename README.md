# AnimalTracker

iPhone app for logging an animal's AAC button presses, feed, poop, and health check-ins, an oral AI check-in, and voice recordings with on-device meaning analysis. Design: `docs/superpowers/specs/2026-09-16-animal-tracker-design.md`.

## Build

Prerequisite: `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` and `brew install xcodegen`.

- `scripts/test-packages.sh`  runs the audio and stats package tests on macOS
- `scripts/build-app.sh`      generates the Xcode project and builds for the simulator
- `scripts/test-app.sh`       runs the app tests on the simulator
- `scripts/run-sim.sh`        builds, installs, launches in the simulator, screenshots to build/screenshot.png

To install on a phone with personal signing, set `DEVELOPMENT_TEAM` in `project.yml` to your personal team id, run `xcodegen generate`, then build to the device:
`xcodebuild -project AnimalTracker.xcodeproj -scheme AnimalTracker -destination 'generic/platform=iOS' -allowProvisioningUpdates build`
