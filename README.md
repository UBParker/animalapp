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

## Supabase key

`App/Config/Supabase.plist` carries the project URL and the **anon** key. The anon key is public by
design: it only says `role: anon`, and every table is protected by Row Level Security keyed on
`auth.uid()`. It is committed, and there is no local-only substitution step.

What must never enter the repo: the database password, a secret API key, a legacy service-role key,
and the Supabase personal access token the CLI uses. `scripts/check-secrets.sh` matches the value
shapes of all four and runs automatically from `.githooks/pre-push`. It matches values, not names,
so writing the name of an environment variable in a document is fine. After a fresh clone, run
`git config core.hooksPath .githooks` once.
