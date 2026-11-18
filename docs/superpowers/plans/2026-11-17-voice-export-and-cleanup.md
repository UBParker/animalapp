# Voice Export and Local-only Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ash can tap Settings, Data, Export voice data and save one zip file holding her animals, voice tags, recordings, per-sound measurements and the audio itself; and the local-only build stops showing controls that lead nowhere.

**Architecture:** A voice-only slice of Plan G. `ExportBundle` uses Plan G's version 4 JSON shape with all fifteen top-level keys; the ten keys for domains that do not exist yet (buttons, feed, poop, health, check-in) are always empty arrays of a placeholder type, so a later full Plan G import reads this file unchanged. One builder reads SwiftData; CSV and JSON rendering are pure; one writer copies media into a folder and zips it with `NSFileCoordinator`'s `.forUploading` read. A Settings row runs it and hands the zip to the share sheet. Import is out of scope.

**Tech Stack:** Swift 5, SwiftUI, SwiftData, Foundation, UIKit (`UIActivityViewController`), XCTest on the iOS simulator. No third-party packages.

**Spec:** Agreed in chat on 2026-11-17 (no separate spec file): options 1 and 2 of the four-agent menu. The export format argues from `docs/superpowers/plans/2026-09-18-animal-tracker-G-export-import.md` (Global Constraints and Task 1's export structs) and `docs/superpowers/specs/2026-09-18-model-contract.md` ("Export contract"). The cleanup list is the deferred minors from the 2026-11-10 local-only MVP session.

## Handoff

State on 2026-11-17: branch `feature/animal-voice` at `c0cd73e`, pushed. The local-only MVP is done (`docs/superpowers/plans/2026-11-10-local-only-mvp.md`). App suite 266 tests, packages 28 + 28, all green.

**Agent budget: four.** Task 1 implementer, Task 1 reviewer, Task 2 implementer, Task 2 reviewer. Fix rounds resume the same implementer with SendMessage instead of spawning a new one. There is no separate final whole-branch reviewer: the two task reviews together cover every line of the branch. That is a deliberate trade for the budget, recorded as a ruling in the ledger.

**Run it:**

```bash
cd /Users/asheslab/Documents/work/cat-voice && claude --dangerously-skip-permissions "Read docs/superpowers/plans/2026-11-17-voice-export-and-cleanup.md and execute it with superpowers:subagent-driven-development. Follow ~/.claude/CLAUDE.md agent rules: model opus on every Agent call. Stay within the plan's four-agent budget."
```

## Global Constraints

- Every Agent call sets `model: "opus"`.
- Do not modify anything under `App/Auth/`, `App/Sync/`, `supabase/`, or `project.yml`. `LOCAL_ONLY` stays on.
- iOS deployment target `17.0`; Swift 5 language mode.
- Nothing in this plan touches the network.
- JSON file name `animal-tracker.json`, `"version": 4`, exactly these top-level keys: `version, animals, buttons, presses, feedDays, feedings, feedItems, poopTags, poopObservations, healthCheckIns, oralCheckIns, checkInTurns, voiceTags, voiceRecordings, vocalizations`.
- CSV headers, verbatim:
  - `voice-recordings.csv`: `animal,timestamp_iso8601,duration_s,audio_filename,status,activity,meaning,confidence,note`
  - `vocalizations.csv`: `animal,recording_id,start_s,end_s,f0_mean,f0_min,f0_max,f0_slope,voiced_fraction,rms_db,spectral_centroid_hz,mfcc0,mfcc1,mfcc2,mfcc3,mfcc4,mfcc5,mfcc6,mfcc7,mfcc8,mfcc9,mfcc10,mfcc11,mfcc12,activity,meaning,confidence,overridden`
- Timestamps are ISO 8601 with the local UTC offset and no fractional seconds. Ids are UUID strings. Relationships are ids.
- CSV: RFC 4180 quoting (a field containing a comma, double quote, CR or LF is wrapped in double quotes, inner quotes doubled), `\n` line endings, trailing newline. Doubles via `String(Double)`, nil is an empty field, booleans `true`/`false`.
- The Anthropic API key is never exported.
- Test command: `scripts/test-app.sh`, or its xcodebuild line with `-only-testing:AnimalTrackerTests/<Class>`. One simulator run at a time.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Do not push.

## Decisions (planner's calls)

1. **Media is copied into the export**, unlike Plan G, which references filenames only. The point of this export is a copy that survives losing the phone, and half of the data is audio. Files go under `Media/` in the archive with their store filenames, so the JSON's filenames resolve inside the zip.
2. **One zip, not a folder.** Share-sheet targets handle a single file reliably. `NSFileCoordinator.coordinate(readingItemAt:options: .forUploading, ...)` on a directory hands back a zip of it; the URL is valid only inside the accessor block, so the writer copies it out before returning.
3. **Export structs add `updatedAt: String?`** to `VoiceTagExport`, `VoiceRecordingExport` and `VocalizationExport` (the live models carry it; Plan G was written before it existed). Plan G's refresh must keep these fields.
4. **Archived animals are exported.** An export is a backup, not a view.
5. **Ordering:** every array sorted by `createdAt` ascending, then `id` string, so two exports of the same store produce the same JSON.

## Review Focus

1. **A recording whose audio file is gone from disk.** Expected: the export still succeeds, the row lists the missing name, and the UI says how many files were missing. Pinned by Task 1's `testMissingMediaIsListedNotFatal`.
2. **Notes containing commas, quotes, newlines or emoji.** Expected: valid CSV that a spreadsheet opens with each note in one cell. Pinned by Task 1's CSVWriter tests and `testRecordingNoteWithCommaAndNewlineIsQuoted`.
3. **An empty store** (no animals yet). Expected: a valid zip whose JSON has all fifteen keys and empty arrays. Pinned by Task 1's `testEmptyStoreProducesAllKeys`.
4. **The temporary store after a failed open** (`store.recovered == true`). Expected: the Export row says the export holds only this temporary store. Pinned by Task 2's `testRecoveredStoreNoticeShowsOnlyWhenRecovered`.
5. **A long history of audio.** Expected: no memory spike. Files are copied with `FileManager.copyItem`, never read into `Data`; the zip is produced by the system from disk. Checked by Task 1 review, and by Ash on device.

---

### Task 1: Voice export core

**Files:**
- Create: `App/IO/ExportBundle.swift` (`ExportFormatters`, `ExportBundle`, `PendingExport`, `AnimalExport`, `VoiceTagExport`, `VoiceRecordingExport`, `VocalizationExport`; Foundation only)
- Create: `App/IO/ExportBundleBuilder.swift` (the only SwiftData reader)
- Create: `App/IO/CSVWriter.swift`
- Create: `App/IO/VoiceCSVExporter.swift`
- Create: `App/IO/JSONExporter.swift`
- Create: `App/IO/ExportWriter.swift`
- Test: `AppTests/ExportFormattersTests.swift`, `AppTests/CSVWriterTests.swift`, `AppTests/ExportBundleBuilderTests.swift`, `AppTests/VoiceCSVExporterTests.swift`, `AppTests/ExportWriterTests.swift`

**Interfaces:**
- Consumes: models `Animal`, `VoiceTag`, `VoiceRecording`, `Vocalization` (`App/Models/`); `MediaStore` and `MediaNaming.isValid` (`App/Media/MediaStore.swift`); `TestSupport.container()` for in-memory stores; `FileMediaStore(root:)` for a temporary media directory in tests.
- Produces:
  - `enum ExportFormatters { static func timestamp(_: Date) -> String; static func optionalTimestamp(_: Date?) -> String?; static func decimal(_: Double?) -> String; static func integer(_: Int?) -> String; static func flag(_: Bool) -> String }`
  - `struct ExportBundle: Codable, Equatable` with `static let currentVersion = 4` and the fifteen keys; `animals: [AnimalExport]`, `voiceTags: [VoiceTagExport]`, `voiceRecordings: [VoiceRecordingExport]`, `vocalizations: [VocalizationExport]`, every other key `[PendingExport]` defaulting to `[]`. `struct PendingExport: Codable, Equatable {}` carries a doc comment saying Plan G replaces each use with the real type.
  - Export struct fields: Plan G Task 1's `AnimalExport`, `VoiceTagExport`, `VoiceRecordingExport`, `VocalizationExport` field for field (Plan G plan file, lines 288-300 and 410-453), plus `updatedAt: String?` on the three voice types.
  - `enum ExportBundleBuilder { @MainActor static func build(context: ModelContext) throws -> ExportBundle }`
  - `enum CSVWriter { static func field(_: String) -> String; static func document(header: [String], rows: [[String]]) -> String }`
  - `enum VoiceCSVExporter { static let recordingsHeader: [String]; static let vocalizationsHeader: [String]; static func recordings(_: ExportBundle) -> String; static func vocalizations(_: ExportBundle) -> String }`
  - `enum JSONExporter { static func data(_: ExportBundle) throws -> Data }` (pretty-printed, sorted keys)
  - `struct ExportResult: Equatable { let archiveURL: URL; let missingMedia: [String] }`
  - `enum ExportWriter { static func writeFolder(bundle: ExportBundle, media: MediaStore, parent: URL, now: Date) throws -> (folder: URL, missingMedia: [String]); static func archive(folder: URL) throws -> URL; static func write(bundle: ExportBundle, media: MediaStore, parent: URL = FileManager.default.temporaryDirectory, now: Date = Date()) throws -> ExportResult }`

- [ ] **Step 1: Write the failing tests.**
  - `ExportFormattersTests.testTimestampHasOffsetAndNoFraction`: `timestamp(Date(timeIntervalSince1970: 1_790_000_000.75))` matches `^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(Z|[+-]\d{2}:\d{2})$`. Plus `decimal(nil) == ""`, `decimal(2) == "2.0"`, `integer(nil) == ""`, `flag(true) == "true"`.
  - `CSVWriterTests`: `field("plain") == "plain"`; `field("a,b") == "\"a,b\""`; `field("say \"hi\"") == "\"say \"\"hi\"\"\""`; `field("line1\nline2") == "\"line1\nline2\""`; `field("🐴") == "🐴"`; `document(header: ["a","b"], rows: [["1","2"]]) == "a,b\n1,2\n"`.
  - `ExportBundleBuilderTests` (in-memory container: one archived animal "Juniper", one custom meaning tag, one recording for Juniper with one vocalization, and one recording with `animal == nil`):
    - `testRelationshipsAreIds`: the vocalization's `recordingId` equals the first recording's `id.uuidString`; that recording's `animalId` equals Juniper's id string; the animal-less recording has `animalId == nil`.
    - `testArchivedAnimalIsExported`: `bundle.animals.count == 1`, `isArchived == true`.
    - `testOrderIsCreatedAtThenId`: two recordings with equal `createdAt` come out ordered by `id.uuidString`.
    - `testEmptyStoreProducesAllKeys`: build from an empty container, encode with `JSONExporter.data`, decode as `[String: Any]` via `JSONSerialization`; the key set equals the fifteen keys from Global Constraints, `version == 4`, every array empty. (The seeded built-in voice tags are allowed in `voiceTags`; assert on the other fourteen.)
  - `VoiceCSVExporterTests`:
    - `testHeadersVerbatim`: the first line of each document equals the Global Constraints header joined by commas.
    - `testRecordingRowUsesAnimalName`: Juniper's recording row starts with `Juniper,`; the animal-less recording row starts with `,`.
    - `testShortMfccPadsEmpty`: a vocalization with `mfcc` of 3 values yields 10 empty `mfcc3` to `mfcc12` fields; a 15-value array is truncated to 13.
    - `testRecordingNoteWithCommaAndNewlineIsQuoted`: note `"ate, then\nslept"` appears as `"ate, then\nslept"` in quotes.
  - `ExportWriterTests` (temporary directory per test, `FileMediaStore(root:)` under it, one real audio file written into the store, plus a recording that names `missing-audio.m4a`):
    - `testFolderHoldsJsonCsvAndMedia`: `writeFolder` produces `animal-tracker.json`, `voice-recordings.csv`, `vocalizations.csv`, and `Media/<the present audio filename>` with the same byte count as the source.
    - `testMissingMediaIsListedNotFatal`: `missingMedia == ["missing-audio.m4a"]`, no throw.
    - `testInvalidFilenameIsListedNotCopied`: a recording whose `audioFilename` is `"../escape.m4a"` is listed in `missingMedia` and nothing is written outside `Media/`.
    - `testArchiveIsAZip`: `write(...)` returns an `archiveURL` with extension `zip` that exists, whose first two bytes are `0x50 0x4B` ("PK"), and the working folder no longer exists afterwards.
    - `testTwoExportsDoNotCollide`: two `write` calls with the same `now` return different `archiveURL`s.
- [ ] **Step 2: Run them.** Focused classes. Expected: compile failure, the new types are not found.
- [ ] **Step 3: Implement** the Produces list. Notes the signatures leave open:
  - `ExportFormatters.timestamp`: `ISO8601DateFormatter` with `formatOptions = [.withInternetDateTime]` and `timeZone = .current`.
  - `VoiceCSVExporter`: `animal` is the animal's name looked up by `animalId` (empty if nil or not found); for vocalizations, via the recording's `animalId`. `timestamp_iso8601` is `recordedAt`. `confidence` is `userConfidence`. `activity`/`meaning` are the tag strings.
  - `ExportWriter.writeFolder`: folder name `AnimalTracker-export-<yyyy-MM-dd>-<8 lowercase hex from a fresh UUID>` under `parent`. Media to copy: every recording's `audioFilename`, every animal's `photoFilename` and `photoThumbnailFilename`, deduplicated, skipping empty strings. A name that fails `MediaNaming.isValid` or `media.exists` goes to `missingMedia` (sorted) instead. Copy with `FileManager.copyItem`, never through `Data`.
  - `ExportWriter.archive`: coordinate a `.forUploading` read of the folder, copy the provided zip to `<folder path>.zip`, return it. Throw if the coordinator reports an error.
  - `ExportWriter.write`: `writeFolder`, then `archive`, then remove the folder.
- [ ] **Step 4: Run the focused classes, then `scripts/test-app.sh`.** Expected: all green, about 21 more tests than 266.
- [ ] **Step 5: Commit** `feat(export): build a voice data archive with audio, JSON and CSV`.

### Task 2: Export row in Settings and local-only cleanup

**Files:**
- Create: `App/Views/Settings/ShareSheet.swift`
- Create: `App/Views/Settings/ExportDataRow.swift`
- Create: `App/Views/Shared/RecoveredStoreBanner.swift`
- Modify: `App/Views/Settings/SettingsView.swift` (Tags and Data sections; re-indent section bodies)
- Modify: `App/AnimalSwitcher.swift` (`AnimalToolbar` only)
- Modify: `App/Views/LocalRootView.swift`, `App/Views/Auth/RootView.swift` (banner line only), `App/RootTabView.swift` (placeholder text only)
- Modify: `docs/superpowers/reviews/2026-10-26-plan-h-open-defects.md` (the 2026-11-10 entry)
- Test: `AppTests/SettingsSectionsTests.swift`, `AppTests/ExportDataRowTests.swift`, `AppTests/AnimalToolbarTests.swift`

**Interfaces:**
- Consumes: `ExportBundleBuilder.build(context:)`, `ExportWriter.write(bundle:media:)`, `ExportResult` (Task 1); `AppMode.isLocalOnly`; `SettingsSections` (`SettingsView.swift`); `AppStoreLifecycle.recovered`, `\.mediaStore` environment value.
- Produces:
  - `struct ShareSheet: UIViewControllerRepresentable { let items: [Any] }`
  - `struct ExportDataRow: View` plus `enum ExportCopy { static let button = "Export voice data"; static func missingNotice(count: Int) -> String?; static func recoveredNotice(recovered: Bool) -> String? }`
  - `struct RecoveredStoreBanner: View`
  - `extension SettingsSections { static func showsUnbuiltRows(localOnly: Bool) -> Bool }`
  - `extension AnimalToolbar { static func showsCheckIn(localOnly: Bool) -> Bool }`

- [ ] **Step 1: Write the failing tests.**
  - `ExportDataRowTests`: `missingNotice(count: 0) == nil`; `missingNotice(count: 1) == "1 audio or photo file was missing and is not in the export."`; `missingNotice(count: 3) == "3 audio or photo files were missing and are not in the export."`; `testRecoveredStoreNoticeShowsOnlyWhenRecovered`: `recoveredNotice(recovered: false) == nil`, `recoveredNotice(recovered: true) == "The data store could not be opened, so this export holds only what was recorded since the app started."`
  - `SettingsSectionsTests`: change `testFullBuildShowsEverySectionInOrder` to compare against the literal `[.account, .animals, .oralCheckIn, .tags, .data, .about]`; add `showsUnbuiltRows(localOnly: true) == false`, `showsUnbuiltRows(localOnly: false) == true`.
  - `AnimalToolbarTests`: `showsCheckIn(localOnly: true) == false`, `showsCheckIn(localOnly: false) == true`.
- [ ] **Step 2: Run them.** Expected: compile failure.
- [ ] **Step 3: Implement.**
  - `ExportDataRow`: a button labeled `ExportCopy.button`. On tap: disable and show a `ProgressView`; build the bundle on the main actor from `@Environment(\.modelContext)`; run `ExportWriter.write` in `Task.detached`; on success present `ShareSheet(items: [archiveURL])` in a sheet. Below the button, footnotes for `recoveredNotice(recovered: store.recovered)` (secondary color), `missingNotice` (orange) and any thrown error (red, `String(describing:)`). Delete the archive from the temporary directory when the share sheet is dismissed.
  - `SettingsView` Data section: `ExportDataRow()` replaces the Export placeholder; the Import placeholder shows only when `showsUnbuiltRows`. Tags section: the "Poop tags" placeholder shows only when `showsUnbuiltRows`. Re-indent every section body one level inside its `if` block as a separate whitespace-only commit.
  - `AnimalToolbar`: the check-in button and its sheet only when `showsCheckIn(localOnly: AppMode.isLocalOnly)`.
  - `RecoveredStoreBanner`: the existing yellow banner (text and four modifiers exactly as in `LocalRootView.swift:28-33`); `LocalRootView` and `RootView` both use it. Correct the `LocalRootView` comment on `configureSync`: it is a no-op until something assigns `store.sync`.
  - `RootTabView.content(for:)`: placeholder tabs show `Text(rootTab.title)`.
  - Open-defects doc, 2026-11-10 entry: say `leaveOfflineMode` is the DEBUG offline path, so the Release wipe comes from `StoreOwnerPolicy` on sign-in. Add that voice export now exists but nothing imports it back, so after a wipe the data could be read from the zip but not restored into the app; the blocker stands until the adoption path or Plan G import exists.
- [ ] **Step 4: Run the full suite, then `scripts/run-sim.sh`.** Expected: green; screenshot shows the first-run Add Animal sheet as before.
- [ ] **Step 5: Commit** `feat(settings): export voice data from Settings`, `style(settings): indent section bodies inside their visibility checks`, and `chore: hide unbuilt controls in local-only mode and tidy deferred minors`, in that order or fewer if the split is awkward.
- [ ] **Step 6: Report to Ash.** On device: Settings, Data, Export voice data, Save to Files; open the zip in Files and check that `animal-tracker.json` opens, both CSVs open in Numbers, and an audio file under `Media/` plays.
