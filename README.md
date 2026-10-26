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

The real key is not in the tree yet: the plist still holds `REPLACE_WITH_ANON_KEY`. Commit 219ae15
says "commit the anon key" in its subject, but only the placeholder landed, and that commit is not
being rewritten. Until someone substitutes the real value, a Debug build runs in offline mode and a
Release build refuses to compile.

What must never enter the repo: the database password, a secret API key, a legacy service-role key,
and the Supabase personal access token the CLI uses. `scripts/check-secrets.sh` matches the value
shapes of all four and runs automatically from `.githooks/pre-push`. It matches values, not names,
so writing the name of an environment variable in a document is fine. After a fresh clone, run
`git config core.hooksPath .githooks` once.

The hook scans the commit range it is about to push as well as the working tree, so a secret that
was committed and then deleted in a later commit is still caught. `scripts/check-secrets.sh` takes
the same range arguments by hand (`scripts/check-secrets.sh origin/main..HEAD`) and with no
arguments scans the working tree only. It exits 0 clean, 1 on a finding, 2 when it could not run.
`scripts/check-secrets-selftest.sh` proves all of that against a throwaway repository under
`$TMPDIR`; it pushes nothing and writes no secret to disk.

## Supabase schema

The schema lives in `supabase/migrations/`. To apply it:

```bash
read -rs SUPABASE_ACCESS_TOKEN && export SUPABASE_ACCESS_TOKEN
supabase link --project-ref ojzmtyapkaxxliuurssc
supabase db push
unset SUPABASE_ACCESS_TOKEN
```

The access token and the database password are never stored in the repo. Without the CLI, apply
the same file with `psql "$PGURI" -v ON_ERROR_STOP=1 -f supabase/migrations/<file>.sql`.

If the `storage.objects` policies are refused with `must be owner of table objects`, replay just
that block after `set role supabase_storage_admin;` (see Plan H Task 6 Step 7).
