# AnimalTracker Plan G: Export and Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Export every record in the store as six CSV files plus `animal-tracker.json` through a share sheet, and import an `animal-tracker.json` back by merging on id after a counted confirmation.

**Architecture:** A value type `ExportBundle` holds Codable snapshot structs for all fourteen models. `ExportBundleBuilder` is the only file that reads SwiftData; `CSVExporter`, `JSONExporter` and the validating half of `JSONImporter` are pure functions over the bundle, so almost the whole subsystem is unit-tested without a container. `JSONImporter.merge` is the one writing path: it resolves parents first, updates or inserts by id, and saves once. Two rows in `SettingsView` drive it, an export row that writes seven files into a fresh temporary folder and hands them to `UIActivityViewController`, and an import row that decodes, previews counts, asks, then merges.

**Tech Stack:** Swift 5 language mode, iOS 17, SwiftUI, SwiftData, Foundation, UIKit (`UIActivityViewController`), UniformTypeIdentifiers (`.json` for `fileImporter`), XCTest. No third-party packages, no iCloud.

**Spec:** `docs/superpowers/specs/2026-09-16-animal-tracker-design.md` (sections: Constraints, Data model, Data handling, Error handling, Project layout IO/, Testing) and `docs/superpowers/specs/2026-09-18-model-contract.md` (binding model names and fields, export contract). Plan A is `docs/superpowers/plans/2026-09-18-animal-tracker-A-foundation.md`. Plans B through F are implemented before this one, so every model in the contract exists exactly as written.

## Global Constraints

- iOS deployment target `17.0`; Swift 5 language mode (`SWIFT_VERSION = 5.0`); never Swift 6 strict concurrency.
- App target `AnimalTracker`, test target `AnimalTrackerTests`. Test files use `@testable import AnimalTracker`.
- No iCloud, no third-party packages, no analytics. Nothing in this plan touches the network.
- Tests are XCTest under `AppTests/`, written test-first, run with `scripts/test-app.sh`.
- Every model has `id: UUID = UUID()` and `createdAt: Date = Date()`. Enums are stored as `<name>Raw: String`.
- CSV headers and column order are fixed by the spec, verbatim:
  - `presses.csv`: `animal,timestamp_iso8601,button,kind,note`
  - `feedings.csv`: `animal,date,outdoor_hours,outdoor_area_acres,feeding_time_iso8601,category,type,amount,unit,feeding_note`, one row per FeedItem, a feeding with no items produces one row with empty item columns
  - `poop.csv`: `animal,timestamp_iso8601,tags,note`, tags pipe-separated
  - `health.csv`: `animal,timestamp_iso8601,photo_filename,video_filename,note`
  - `voice-recordings.csv`: `animal,timestamp_iso8601,duration_s,audio_filename,status,activity,meaning,confidence,note`
  - `vocalizations.csv`: `animal,recording_id,start_s,end_s,f0_mean,f0_min,f0_max,f0_slope,voiced_fraction,rms_db,spectral_centroid_hz,mfcc0` through `mfcc12`, then `activity,meaning,confidence,overridden`
- JSON file `animal-tracker.json` with `"version": 4` and exactly these top-level keys: `version, animals, buttons, presses, feedDays, feedings, feedItems, poopTags, poopObservations, healthCheckIns, oralCheckIns, checkInTurns, voiceTags, voiceRecordings, vocalizations`.
- Timestamps are ISO 8601 with the local UTC offset and no fractional seconds. FeedDay `date` exports as `yyyy-MM-dd`.
- Ids are UUID strings; relationships are carried by id; media is referenced by filename only and never embedded.
- Import rejects an unknown `version` and every dangling reference, naming the problem; then merges by id inside one save.
- The Anthropic API key lives in the keychain and is never exported.
- Commit after every task with the message shown, ending in the trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. Do not push.

## Assumptions

Decisions the spec left open, and how this plan resolves them.

1. **`poop.csv` header.** The spec writes the column as `tags (pipe-separated)`. That parenthetical describes the value format, not the header text, so the header column is `tags` and values are joined with `|`.
2. **Line terminator.** RFC 4180 names CRLF, but the spec only asks for RFC 4180 quoting. Files use `\n` line endings with a trailing newline. Quoting follows RFC 4180 exactly: a field containing a comma, a double quote, CR or LF is wrapped in double quotes and inner quotes are doubled.
3. **Number formatting.** Doubles are written with Swift's `String(Double)` (`2.0`, `0.5`, `-160.0`), which is deterministic and round-trips. A nil number is an empty field. Booleans are `true` or `false`.
4. **UTC time zone.** `ISO8601DateFormatter` renders a zero offset as `Z`. That is a correct ISO 8601 offset, so a simulator set to UTC produces `2026-09-18T15:26:40Z` and a simulator in Los Angeles produces `2026-09-18T08:26:40-07:00`. Tests assert the shape with a regular expression rather than a hardcoded offset.
5. **JSON relationship key names.** The spec fixes the top-level keys only. Relationship fields are named `animalId`, `buttonId`, `dayId`, `feedingId`, `checkInId`, `recordingId` and `tagIds`.
6. **Feeding to missing feed day** is validated as a dangling reference too, by the same rule the spec gives for item to missing feeding.
7. **A feed day with no feedings** produces no row in `feedings.csv`. It still appears in the JSON. The spec only specifies the empty-items case.
8. **Where the export structs live.** They are Codable wire types, so they live in `App/IO/ExportBundle.swift`, not in `App/Logic/Snapshots.swift`, which holds the UI snapshots the model contract lists. Plan G adds nothing to `Snapshots.swift`.
9. **Model construction.** Every model except `Animal` is created with the SwiftData-synthesized memberwise initializer with no arguments (`Press()`, `FeedItem()`, and so on), which exists because the contract gives every stored property a default or makes it optional. `Animal` keeps Plan A's `init(name:species:colorHex:tracksOutdoorTime:sortOrder:)`. If a sibling plan hand-wrote an initializer on one of its models, keep a no-argument one alongside it.
10. **Import never deletes.** Records present in the store but absent from the file are left alone. Merge is update-or-insert only.
11. **Media on import.** Only filenames are imported. The importer never asks whether a file exists, so a check-in or recording whose media is gone imports cleanly; showing a placeholder is the other plans' concern.
12. **Short `mfcc` arrays.** The analyzer always writes thirteen coefficients. If an array is shorter, the missing `mfccN` columns are empty; longer arrays are truncated to thirteen.
13. **Export folder.** Each export writes into a fresh `AnimalTracker-export-<yyyy-MM-dd>-<8 hex>` directory under the temporary directory, so repeat exports never collide and the share sheet always sees seven current files.
14. **Export runs synchronously on the main actor.** The store holds a phone's worth of hand-logged records, so a background pass is not worth the complexity.

## File Structure

```
App/IO/ExportBundle.swift            ExportBundle + fourteen Codable export structs + ExportFormatters (Foundation only)
App/IO/ExportBundleBuilder.swift     the only SwiftData reader: models -> ExportBundle, deterministically ordered
App/IO/CSVWriter.swift               RFC 4180 field quoting, row and document assembly
App/IO/CSVExporter.swift             the six CSV documents, pure over ExportBundle
App/IO/JSONExporter.swift            animal-tracker.json bytes, pure over ExportBundle
App/IO/JSONImporter.swift            ImportError, ImportCounts, EntityNames, decode + validate + preview + merge
App/IO/ExportWriter.swift            temporary folder and the seven files on disk
App/Views/Settings/ShareSheet.swift  UIActivityViewController wrapper
App/Views/Settings/ExportDataRow.swift   Settings row: build, write, share
App/Views/Settings/ImportDataRow.swift   Settings row: pick, preview counts, confirm, merge, report
App/Views/Settings/SettingsView.swift    replace the two SettingsPlaceholderRow lines in the Data section
AppTests/ExportTestFixtures.swift    in-memory container populated with one row of every model
AppTests/ExportFormattersTests.swift, ExportBundleCodableTests.swift, ExportBundleBuilderTests.swift,
         CSVWriterTests.swift, CSVExporterCoreTests.swift, CSVExporterFeedTests.swift, CSVExporterVoiceTests.swift,
         JSONExporterTests.swift, JSONImportValidationTests.swift, JSONImporterMergeTests.swift,
         JSONRoundTripTests.swift, ExportWriterTests.swift
```

Plan G registers no models and no seeds, so `PersistenceController.modelTypes`, `Seeds.all`, `AnimalDeletionPolicy.recordCounts` and `RootTabView` are untouched. The only Plan A file it edits is `SettingsView.swift`.

---

### Task 1: Export value types and shared formatting

**Files:**
- Create: `App/IO/ExportBundle.swift`
- Test: `AppTests/ExportFormattersTests.swift`, `AppTests/ExportBundleCodableTests.swift`

**Interfaces:**
- Consumes: nothing from earlier plans. Foundation only, no SwiftData import.
- Produces: `enum ExportFormatters` with `timestamp(_ date: Date) -> String`, `optionalTimestamp(_ date: Date?) -> String?`, `date(fromTimestamp: String) -> Date?`, `day(_ date: Date) -> String`, `date(fromDay: String) -> Date?`, `decimal(_ value: Double?) -> String`, `integer(_ value: Int?) -> String`, `flag(_ value: Bool) -> String`, `text(_ value: String?) -> String`; `struct ExportBundle: Codable, Equatable` with `static let currentVersion = 4` and `var version, animals, buttons, presses, feedDays, feedings, feedItems, poopTags, poopObservations, healthCheckIns, oralCheckIns, checkInTurns, voiceTags, voiceRecordings, vocalizations`, every field defaulted so `ExportBundle()` compiles; `AnimalExport, ButtonExport, PressExport, FeedDayExport, FeedingExport, FeedItemExport, PoopTagExport, PoopObservationExport, HealthCheckInExport, OralCheckInExport, CheckInTurnExport, VoiceTagExport, VoiceRecordingExport, VocalizationExport`, all `Codable, Equatable`, all stored properties `var` with defaults.

**Tests added: 7.**

- [ ] **Step 1: Write the failing tests**

`AppTests/ExportFormattersTests.swift`:
```swift
import XCTest
@testable import AnimalTracker

final class ExportFormattersTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_789_000_000.75)

    func testTimestampIsISO8601WithOffsetAndNoFractionalSeconds() {
        let text = ExportFormatters.timestamp(instant)
        let pattern = "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}([+-]\\d{2}:\\d{2}|Z)$"
        XCTAssertNotNil(text.range(of: pattern, options: .regularExpression), text)
        XCTAssertFalse(text.contains("."), text)
        XCTAssertNil(ExportFormatters.optionalTimestamp(nil))
        XCTAssertEqual(ExportFormatters.optionalTimestamp(instant), text)
    }

    func testTimestampRoundTripsBackToTheWholeSecond() {
        let text = ExportFormatters.timestamp(instant)
        let parsed = ExportFormatters.date(fromTimestamp: text)
        XCTAssertEqual(parsed?.timeIntervalSince1970, 1_789_000_000)
        XCTAssertEqual(ExportFormatters.timestamp(XCTUnwrap0(parsed)), text)
        XCTAssertNil(ExportFormatters.date(fromTimestamp: "not a date"))
    }

    func testDayIsYearMonthDayAndRoundTripsToLocalStartOfDay() {
        let day = ExportFormatters.day(instant)
        XCTAssertNotNil(day.range(of: "^\\d{4}-\\d{2}-\\d{2}$", options: .regularExpression), day)
        let parsed = XCTUnwrap0(ExportFormatters.date(fromDay: day))
        XCTAssertEqual(parsed, Calendar.current.startOfDay(for: parsed))
        XCTAssertEqual(ExportFormatters.day(parsed), day)
        XCTAssertNil(ExportFormatters.date(fromDay: "2026-13-99"))
    }

    func testNumberTextAndFlagHelpers() {
        XCTAssertEqual(ExportFormatters.decimal(2), "2.0")
        XCTAssertEqual(ExportFormatters.decimal(0.5), "0.5")
        XCTAssertEqual(ExportFormatters.decimal(-160), "-160.0")
        XCTAssertEqual(ExportFormatters.decimal(nil), "")
        XCTAssertEqual(ExportFormatters.integer(2), "2")
        XCTAssertEqual(ExportFormatters.integer(nil), "")
        XCTAssertEqual(ExportFormatters.flag(true), "true")
        XCTAssertEqual(ExportFormatters.flag(false), "false")
        XCTAssertEqual(ExportFormatters.text(nil), "")
        XCTAssertEqual(ExportFormatters.text("hay"), "hay")
    }

    /// Small non-throwing unwrap so these assertions read in one line.
    private func XCTUnwrap0<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) -> T {
        guard let value else {
            XCTFail("unexpected nil", file: file, line: line)
            fatalError("unexpected nil")
        }
        return value
    }
}
```

`AppTests/ExportBundleCodableTests.swift`:
```swift
import XCTest
@testable import AnimalTracker

final class ExportBundleCodableTests: XCTestCase {
    func testEmptyBundleHasVersionFourAndFourteenEmptyArrays() {
        let bundle = ExportBundle()
        XCTAssertEqual(bundle.version, 4)
        XCTAssertEqual(ExportBundle.currentVersion, 4)
        XCTAssertTrue(bundle.animals.isEmpty)
        XCTAssertTrue(bundle.buttons.isEmpty)
        XCTAssertTrue(bundle.presses.isEmpty)
        XCTAssertTrue(bundle.feedDays.isEmpty)
        XCTAssertTrue(bundle.feedings.isEmpty)
        XCTAssertTrue(bundle.feedItems.isEmpty)
        XCTAssertTrue(bundle.poopTags.isEmpty)
        XCTAssertTrue(bundle.poopObservations.isEmpty)
        XCTAssertTrue(bundle.healthCheckIns.isEmpty)
        XCTAssertTrue(bundle.oralCheckIns.isEmpty)
        XCTAssertTrue(bundle.checkInTurns.isEmpty)
        XCTAssertTrue(bundle.voiceTags.isEmpty)
        XCTAssertTrue(bundle.voiceRecordings.isEmpty)
        XCTAssertTrue(bundle.vocalizations.isEmpty)
    }

    func testPopulatedBundleRoundTripsThroughJSONCoding() throws {
        var bundle = ExportBundle()
        bundle.animals = [AnimalExport(id: "A1", createdAt: "2026-09-18T08:00:00Z", name: "Juniper",
                                       species: "horse", colorHex: "#2A78D6", note: "lead mare")]
        bundle.vocalizations = [VocalizationExport(id: "V1", recordingId: "R1", startS: 0.5, endS: 1.25,
                                                   f0Mean: 420.5, voicedFraction: 0.8, rmsDb: -22.5,
                                                   spectralCentroidHz: 1800,
                                                   mfcc: (0..<13).map { Double($0) * 1.5 },
                                                   meaningTag: "hungry", userConfidence: 2, overridden: true)]
        let data = try JSONEncoder().encode(bundle)
        XCTAssertEqual(try JSONDecoder().decode(ExportBundle.self, from: data), bundle)
    }

    func testNilOptionalsAreOmittedAndDecodeBackAsNil() throws {
        var bundle = ExportBundle()
        bundle.presses = [PressExport(id: "P1", animalId: "A1", buttonId: "B1",
                                      timestamp: "2026-09-18T08:00:00Z", kind: "spontaneous")]
        let data = try JSONEncoder().encode(bundle)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let press = try XCTUnwrap((object["presses"] as? [[String: Any]])?.first)
        XCTAssertNil(press["note"])
        XCTAssertNil(press["editedAt"])
        XCTAssertEqual(try JSONDecoder().decode(ExportBundle.self, from: data).presses[0].note, nil)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test-app.sh`
Expected: build errors, `ExportFormatters`, `ExportBundle`, `AnimalExport`, `PressExport`, `VocalizationExport` not found.

- [ ] **Step 3: Implement**

`App/IO/ExportBundle.swift`:
```swift
import Foundation

/// String formats shared by the CSV exporter, the JSON exporter, and the importer.
/// Timestamps are ISO 8601 in the device's current time zone, whole seconds only.
/// A zero offset renders as "Z", which is the same instant as "+00:00".
enum ExportFormatters {
    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func timestamp(_ date: Date) -> String { timestampFormatter.string(from: date) }

    static func optionalTimestamp(_ date: Date?) -> String? {
        guard let date else { return nil }
        return timestamp(date)
    }

    static func date(fromTimestamp text: String) -> Date? { timestampFormatter.date(from: text) }

    static func day(_ date: Date) -> String { dayFormatter.string(from: date) }

    static func date(fromDay text: String) -> Date? {
        guard let date = dayFormatter.date(from: text) else { return nil }
        return Calendar.current.startOfDay(for: date)
    }

    /// Plain decimal text, stable across runs. Empty for nil.
    static func decimal(_ value: Double?) -> String {
        guard let value else { return "" }
        return String(value)
    }

    static func integer(_ value: Int?) -> String {
        guard let value else { return "" }
        return String(value)
    }

    static func flag(_ value: Bool) -> String { value ? "true" : "false" }

    static func text(_ value: String?) -> String { value ?? "" }
}

/// Every record in the store as Codable values. Ids are UUID strings, relationships are ids,
/// media is a filename only. This file imports Foundation and nothing else, so the exporters stay pure.
struct ExportBundle: Codable, Equatable {
    static let currentVersion = 4

    var version: Int = ExportBundle.currentVersion
    var animals: [AnimalExport] = []
    var buttons: [ButtonExport] = []
    var presses: [PressExport] = []
    var feedDays: [FeedDayExport] = []
    var feedings: [FeedingExport] = []
    var feedItems: [FeedItemExport] = []
    var poopTags: [PoopTagExport] = []
    var poopObservations: [PoopObservationExport] = []
    var healthCheckIns: [HealthCheckInExport] = []
    var oralCheckIns: [OralCheckInExport] = []
    var checkInTurns: [CheckInTurnExport] = []
    var voiceTags: [VoiceTagExport] = []
    var voiceRecordings: [VoiceRecordingExport] = []
    var vocalizations: [VocalizationExport] = []
}

struct AnimalExport: Codable, Equatable {
    var id: String = ""
    var createdAt: String = ""
    var name: String = ""
    var species: String = ""
    var colorHex: String = ""
    var photoFilename: String?
    var photoThumbnailFilename: String?
    var tracksOutdoorTime: Bool = false
    var sortOrder: Int = 0
    var isArchived: Bool = false
    var note: String?
}

struct ButtonExport: Codable, Equatable {
    var id: String = ""
    var createdAt: String = ""
    var animalId: String?
    var label: String = ""
    var colorHex: String = ""
    var sortOrder: Int = 0
    var isArchived: Bool = false
}

struct PressExport: Codable, Equatable {
    var id: String = ""
    var createdAt: String = ""
    var animalId: String?
    var buttonId: String?
    var timestamp: String = ""
    var kind: String = ""
    var note: String?
    var editedAt: String?
}

struct FeedDayExport: Codable, Equatable {
    var id: String = ""
    var createdAt: String = ""
    var animalId: String?
    /// yyyy-MM-dd, the local calendar day.
    var date: String = ""
    var outdoorHours: Double?
    var outdoorAreaAcres: Double?
    var note: String?
}

struct FeedingExport: Codable, Equatable {
    var id: String = ""
    var createdAt: String = ""
    var dayId: String?
    var time: String = ""
    var note: String?
}

struct FeedItemExport: Codable, Equatable {
    var id: String = ""
    var createdAt: String = ""
    var feedingId: String?
    var category: String = ""
    var type: String = ""
    var amount: Double = 0
    var unit: String = ""
    var sortOrder: Int = 0
}

struct PoopTagExport: Codable, Equatable {
    var id: String = ""
    var createdAt: String = ""
    var name: String = ""
    var colorHex: String = ""
    var isBuiltIn: Bool = false
    var isHidden: Bool = false
    var sortOrder: Int = 0
}

struct PoopObservationExport: Codable, Equatable {
    var id: String = ""
    var createdAt: String = ""
    var animalId: String?
    var timestamp: String = ""
    var tagIds: [String] = []
    var note: String?
    var editedAt: String?
}

struct HealthCheckInExport: Codable, Equatable {
    var id: String = ""
    var createdAt: String = ""
    var animalId: String?
    var timestamp: String = ""
    var photoFilename: String?
    var thumbnailFilename: String?
    var videoFilename: String?
    var note: String?
    var editedAt: String?
}

struct OralCheckInExport: Codable, Equatable {
    var id: String = ""
    var createdAt: String = ""
    var animalId: String?
    var startedAt: String = ""
    var endedAt: String?
    var status: String = ""
    var model: String = ""
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var createdRecordIdsJSON: String = "[]"
    var errorMessage: String?
}

struct CheckInTurnExport: Codable, Equatable {
    var id: String = ""
    var createdAt: String = ""
    var checkInId: String?
    var index: Int = 0
    var role: String = ""
    var text: String = ""
    var timestamp: String = ""
    var draftJSON: String?
}

struct VoiceTagExport: Codable, Equatable {
    var id: String = ""
    var createdAt: String = ""
    var kind: String = ""
    var name: String = ""
    var isBuiltIn: Bool = false
    var sortOrder: Int = 0
}

struct VoiceRecordingExport: Codable, Equatable {
    var id: String = ""
    var createdAt: String = ""
    var animalId: String?
    var recordedAt: String = ""
    var durationS: Double = 0
    var audioFilename: String = ""
    var status: String = ""
    var errorMessage: String?
    var note: String = ""
    var activityTag: String?
    var meaningTag: String?
    var userConfidence: Int?
    var editedAt: String?
}

struct VocalizationExport: Codable, Equatable {
    var id: String = ""
    var createdAt: String = ""
    var recordingId: String?
    var startS: Double = 0
    var endS: Double = 0
    var f0Mean: Double?
    var f0Min: Double?
    var f0Max: Double?
    var f0Slope: Double?
    var voicedFraction: Double = 0
    var rmsDb: Double = -160
    var spectralCentroidHz: Double = 0
    var mfcc: [Double] = []
    var activityTag: String?
    var meaningTag: String?
    var userConfidence: Int?
    var overridden: Bool = false
}
```

- [ ] **Step 4: Run to verify pass**

Run: `scripts/test-app.sh`
Expected: 7 more tests than before this task, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add App/IO/ExportBundle.swift AppTests/ExportFormattersTests.swift AppTests/ExportBundleCodableTests.swift
git commit -m "feat(io): Codable export value types and shared ISO 8601 formatting

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: ExportBundleBuilder over an in-memory container

**Files:**
- Create: `App/IO/ExportBundleBuilder.swift`
- Test: `AppTests/ExportTestFixtures.swift`, `AppTests/ExportBundleBuilderTests.swift`

**Interfaces:**
- Consumes: `ExportBundle` and the fourteen export structs plus `ExportFormatters` from Task 1; every model in the contract; `TestSupport.container() throws -> ModelContainer` from Plan A.
- Produces: `enum ExportBundleBuilder` with `static func build(context: ModelContext) throws -> ExportBundle`, deterministically ordered; test helper `enum ExportTestFixtures` with `static func id(_ n: Int) -> UUID`, `static let base: Date`, `static func populatedContainer() throws -> ModelContainer`, `@discardableResult static func populate(_ context: ModelContext) throws -> Animal`.

**Tests added: 4.**

- [ ] **Step 1: Write the fixture and the failing tests**

`AppTests/ExportTestFixtures.swift`:
```swift
import Foundation
import SwiftData
@testable import AnimalTracker

/// One in-memory container holding at least one row of every model, with fixed ids and dates
/// so export output is byte-stable across runs. Notes contain commas and quotes on purpose.
@MainActor
enum ExportTestFixtures {
    static func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
    }

    static let base = Date(timeIntervalSince1970: 1_789_000_000)

    static func populatedContainer() throws -> ModelContainer {
        let container = try TestSupport.container()
        try populate(container.mainContext)
        return container
    }

    @discardableResult
    static func populate(_ context: ModelContext) throws -> Animal {
        let horse = Animal(name: "Juniper", species: "horse")
        horse.id = id(1)
        horse.createdAt = base
        horse.colorHex = "#2A78D6"
        horse.photoFilename = "aaa-photo.jpg"
        horse.photoThumbnailFilename = "aaa-thumb.jpg"
        horse.note = "lead mare, the \"boss\""
        context.insert(horse)

        let button = AACButton()
        button.id = id(2)
        button.createdAt = base
        button.label = "Out"
        button.colorHex = "#2A78D6"
        button.sortOrder = 0
        button.animal = horse
        context.insert(button)

        let press = Press()
        press.id = id(3)
        press.createdAt = base
        press.timestamp = base.addingTimeInterval(60)
        press.kindRaw = PressKind.spontaneous.rawValue
        press.note = "pushed hard, then \"again\""
        press.button = button
        press.animal = horse
        context.insert(press)

        let day = FeedDay()
        day.id = id(4)
        day.createdAt = base
        day.date = Calendar.current.startOfDay(for: base)
        day.outdoorHours = 6.5
        day.outdoorAreaAcres = 2
        day.note = "windy"
        day.animal = horse
        context.insert(day)

        let feeding = Feeding()
        feeding.id = id(5)
        feeding.createdAt = base
        feeding.time = base.addingTimeInterval(3600)
        feeding.note = "morning, early"
        feeding.day = day
        context.insert(feeding)

        let item = FeedItem()
        item.id = id(6)
        item.createdAt = base
        item.categoryRaw = FeedCategory.forage.rawValue
        item.type = "hay"
        item.amount = 2
        item.unit = "flakes"
        item.sortOrder = 0
        item.feeding = feeding
        context.insert(item)

        let emptyFeeding = Feeding()
        emptyFeeding.id = id(7)
        emptyFeeding.createdAt = base
        emptyFeeding.time = base.addingTimeInterval(7200)
        emptyFeeding.day = day
        context.insert(emptyFeeding)

        let normal = PoopTag()
        normal.id = id(8)
        normal.createdAt = base
        normal.name = "normal"
        normal.colorHex = "#1BAF7A"
        normal.isBuiltIn = true
        normal.sortOrder = 0
        context.insert(normal)

        let soft = PoopTag()
        soft.id = id(9)
        soft.createdAt = base
        soft.name = "soft"
        soft.colorHex = "#EDA100"
        soft.isBuiltIn = true
        soft.sortOrder = 1
        context.insert(soft)

        let observation = PoopObservation()
        observation.id = id(10)
        observation.createdAt = base
        observation.timestamp = base.addingTimeInterval(120)
        observation.tags = [normal, soft]
        observation.note = "in the field"
        observation.animal = horse
        context.insert(observation)

        let health = HealthCheckIn()
        health.id = id(11)
        health.createdAt = base
        health.timestamp = base.addingTimeInterval(180)
        health.photoFilename = "bbb-photo.jpg"
        health.thumbnailFilename = "bbb-thumb.jpg"
        health.note = "acting normally"
        health.animal = horse
        context.insert(health)

        let checkIn = OralCheckIn()
        checkIn.id = id(12)
        checkIn.createdAt = base
        checkIn.startedAt = base
        checkIn.endedAt = base.addingTimeInterval(300)
        checkIn.statusRaw = CheckInStatus.saved.rawValue
        checkIn.model = "claude-opus-5"
        checkIn.inputTokens = 120
        checkIn.outputTokens = 45
        checkIn.createdRecordIdsJSON = "[]"
        checkIn.animal = horse
        context.insert(checkIn)

        let turn = CheckInTurn()
        turn.id = id(13)
        turn.createdAt = base
        turn.index = 0
        turn.roleRaw = TurnRole.user.rawValue
        turn.text = "Six hours out, two flakes of hay."
        turn.timestamp = base
        turn.checkIn = checkIn
        context.insert(turn)

        let voiceTag = VoiceTag()
        voiceTag.id = id(14)
        voiceTag.createdAt = base
        voiceTag.kindRaw = VoiceTagKind.meaning.rawValue
        voiceTag.name = "hungry"
        voiceTag.isBuiltIn = true
        voiceTag.sortOrder = 0
        context.insert(voiceTag)

        let recording = VoiceRecording()
        recording.id = id(15)
        recording.createdAt = base
        recording.recordedAt = base.addingTimeInterval(240)
        recording.durationS = 12.5
        recording.audioFilename = "ccc-audio.m4a"
        recording.statusRaw = VoiceStatus.analyzed.rawValue
        recording.note = "at the gate"
        recording.activityTag = "waiting at door"
        recording.meaningTag = "hungry"
        recording.userConfidence = 2
        recording.animal = horse
        context.insert(recording)

        let voiced = Vocalization()
        voiced.id = id(16)
        voiced.createdAt = base
        voiced.startS = 0.5
        voiced.endS = 1.25
        voiced.f0Mean = 420.5
        voiced.f0Min = 380
        voiced.f0Max = 470
        voiced.f0Slope = -12.5
        voiced.voicedFraction = 0.8
        voiced.rmsDb = -22.5
        voiced.spectralCentroidHz = 1800
        voiced.mfcc = (0..<13).map { Double($0) * 1.5 }
        voiced.meaningTag = "hungry"
        voiced.userConfidence = 2
        voiced.recording = recording
        context.insert(voiced)

        let unvoiced = Vocalization()
        unvoiced.id = id(17)
        unvoiced.createdAt = base
        unvoiced.startS = 2
        unvoiced.endS = 2.4
        unvoiced.voicedFraction = 0
        unvoiced.rmsDb = -48
        unvoiced.spectralCentroidHz = 900
        unvoiced.mfcc = Array(repeating: 0, count: 13)
        unvoiced.overridden = true
        unvoiced.recording = recording
        context.insert(unvoiced)

        let dog = Animal(name: "Rex, the \"good\" dog", species: "dog")
        dog.id = id(18)
        dog.createdAt = base
        dog.sortOrder = 1
        context.insert(dog)

        try context.save()
        return horse
    }
}
```

`AppTests/ExportBundleBuilderTests.swift`:
```swift
import SwiftData
import XCTest
@testable import AnimalTracker

@MainActor
final class ExportBundleBuilderTests: XCTestCase {
    func testBuildsEveryEntityFromAPopulatedContainer() throws {
        let bundle = try ExportBundleBuilder.build(context: ExportTestFixtures.populatedContainer().mainContext)
        XCTAssertEqual(bundle.version, 4)
        XCTAssertEqual(bundle.animals.count, 2)
        XCTAssertEqual(bundle.buttons.count, 1)
        XCTAssertEqual(bundle.presses.count, 1)
        XCTAssertEqual(bundle.feedDays.count, 1)
        XCTAssertEqual(bundle.feedings.count, 2)
        XCTAssertEqual(bundle.feedItems.count, 1)
        XCTAssertEqual(bundle.poopTags.count, 2)
        XCTAssertEqual(bundle.poopObservations.count, 1)
        XCTAssertEqual(bundle.healthCheckIns.count, 1)
        XCTAssertEqual(bundle.oralCheckIns.count, 1)
        XCTAssertEqual(bundle.checkInTurns.count, 1)
        XCTAssertEqual(bundle.voiceTags.count, 1)
        XCTAssertEqual(bundle.voiceRecordings.count, 1)
        XCTAssertEqual(bundle.vocalizations.count, 2)
    }

    func testRelationshipsAreCarriedByIdAndFieldsAreConverted() throws {
        let bundle = try ExportBundleBuilder.build(context: ExportTestFixtures.populatedContainer().mainContext)
        let horseID = ExportTestFixtures.id(1).uuidString
        XCTAssertEqual(bundle.animals[0].id, horseID)
        XCTAssertEqual(bundle.animals[0].name, "Juniper")
        XCTAssertTrue(bundle.animals[0].tracksOutdoorTime)
        XCTAssertEqual(bundle.buttons[0].animalId, horseID)
        XCTAssertEqual(bundle.presses[0].buttonId, ExportTestFixtures.id(2).uuidString)
        XCTAssertEqual(bundle.presses[0].animalId, horseID)
        XCTAssertEqual(bundle.presses[0].kind, "spontaneous")
        XCTAssertEqual(bundle.feedings[0].dayId, ExportTestFixtures.id(4).uuidString)
        XCTAssertEqual(bundle.feedItems[0].feedingId, ExportTestFixtures.id(5).uuidString)
        XCTAssertEqual(bundle.feedItems[0].category, "forage")
        XCTAssertEqual(bundle.poopObservations[0].tagIds,
                       [ExportTestFixtures.id(8).uuidString, ExportTestFixtures.id(9).uuidString])
        XCTAssertEqual(bundle.checkInTurns[0].checkInId, ExportTestFixtures.id(12).uuidString)
        XCTAssertEqual(bundle.checkInTurns[0].role, "user")
        XCTAssertEqual(bundle.voiceRecordings[0].status, "analyzed")
        XCTAssertEqual(bundle.vocalizations[0].recordingId, ExportTestFixtures.id(15).uuidString)
        XCTAssertEqual(bundle.vocalizations[0].mfcc.count, 13)
        XCTAssertEqual(bundle.feedDays[0].date,
                       ExportFormatters.day(Calendar.current.startOfDay(for: ExportTestFixtures.base)))
        XCTAssertEqual(bundle.healthCheckIns[0].photoFilename, "bbb-photo.jpg")
        XCTAssertNil(bundle.healthCheckIns[0].videoFilename)
    }

    func testOrderingIsDeterministic() throws {
        let container = try ExportTestFixtures.populatedContainer()
        let first = try ExportBundleBuilder.build(context: container.mainContext)
        let second = try ExportBundleBuilder.build(context: container.mainContext)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.animals.map(\.sortOrder), [0, 1])
        XCTAssertEqual(first.feedings.map(\.id),
                       [ExportTestFixtures.id(5).uuidString, ExportTestFixtures.id(7).uuidString])
        XCTAssertEqual(first.vocalizations.map(\.startS), [0.5, 2])
    }

    func testEmptyContainerGivesAnEmptyBundle() throws {
        let bundle = try ExportBundleBuilder.build(context: TestSupport.container().mainContext)
        XCTAssertEqual(bundle, ExportBundle())
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test-app.sh`
Expected: build error, `ExportBundleBuilder` not found.

- [ ] **Step 3: Implement**

`App/IO/ExportBundleBuilder.swift`:
```swift
import Foundation
import SwiftData

/// The only file in the export path that reads SwiftData. Everything downstream is a pure
/// function over the returned value, so exports are unit-tested without a container.
/// Ordering is fixed here so two exports of the same store are byte-identical.
enum ExportBundleBuilder {
    static func build(context: ModelContext) throws -> ExportBundle {
        let animals = try context.fetch(FetchDescriptor<Animal>())
            .sorted { ($0.sortOrder, $0.id.uuidString) < ($1.sortOrder, $1.id.uuidString) }
        let buttons = try context.fetch(FetchDescriptor<AACButton>())
            .sorted { ($0.sortOrder, $0.id.uuidString) < ($1.sortOrder, $1.id.uuidString) }
        let presses = try context.fetch(FetchDescriptor<Press>())
            .sorted { ($0.timestamp, $0.id.uuidString) < ($1.timestamp, $1.id.uuidString) }
        let feedDays = try context.fetch(FetchDescriptor<FeedDay>())
            .sorted { ($0.date, $0.id.uuidString) < ($1.date, $1.id.uuidString) }
        let feedings = try context.fetch(FetchDescriptor<Feeding>())
            .sorted { ($0.time, $0.id.uuidString) < ($1.time, $1.id.uuidString) }
        let feedItems = try context.fetch(FetchDescriptor<FeedItem>())
            .sorted {
                ($0.feeding?.id.uuidString ?? "", $0.sortOrder, $0.id.uuidString)
                    < ($1.feeding?.id.uuidString ?? "", $1.sortOrder, $1.id.uuidString)
            }
        let poopTags = try context.fetch(FetchDescriptor<PoopTag>())
            .sorted { ($0.sortOrder, $0.id.uuidString) < ($1.sortOrder, $1.id.uuidString) }
        let poopObservations = try context.fetch(FetchDescriptor<PoopObservation>())
            .sorted { ($0.timestamp, $0.id.uuidString) < ($1.timestamp, $1.id.uuidString) }
        let healthCheckIns = try context.fetch(FetchDescriptor<HealthCheckIn>())
            .sorted { ($0.timestamp, $0.id.uuidString) < ($1.timestamp, $1.id.uuidString) }
        let oralCheckIns = try context.fetch(FetchDescriptor<OralCheckIn>())
            .sorted { ($0.startedAt, $0.id.uuidString) < ($1.startedAt, $1.id.uuidString) }
        let checkInTurns = try context.fetch(FetchDescriptor<CheckInTurn>())
            .sorted {
                ($0.checkIn?.id.uuidString ?? "", $0.index, $0.id.uuidString)
                    < ($1.checkIn?.id.uuidString ?? "", $1.index, $1.id.uuidString)
            }
        let voiceTags = try context.fetch(FetchDescriptor<VoiceTag>())
            .sorted { ($0.sortOrder, $0.id.uuidString) < ($1.sortOrder, $1.id.uuidString) }
        let voiceRecordings = try context.fetch(FetchDescriptor<VoiceRecording>())
            .sorted { ($0.recordedAt, $0.id.uuidString) < ($1.recordedAt, $1.id.uuidString) }
        let vocalizations = try context.fetch(FetchDescriptor<Vocalization>())
            .sorted {
                ($0.recording?.id.uuidString ?? "", $0.startS, $0.id.uuidString)
                    < ($1.recording?.id.uuidString ?? "", $1.startS, $1.id.uuidString)
            }

        return ExportBundle(
            animals: animals.map(AnimalExport.init(model:)),
            buttons: buttons.map(ButtonExport.init(model:)),
            presses: presses.map(PressExport.init(model:)),
            feedDays: feedDays.map(FeedDayExport.init(model:)),
            feedings: feedings.map(FeedingExport.init(model:)),
            feedItems: feedItems.map(FeedItemExport.init(model:)),
            poopTags: poopTags.map(PoopTagExport.init(model:)),
            poopObservations: poopObservations.map(PoopObservationExport.init(model:)),
            healthCheckIns: healthCheckIns.map(HealthCheckInExport.init(model:)),
            oralCheckIns: oralCheckIns.map(OralCheckInExport.init(model:)),
            checkInTurns: checkInTurns.map(CheckInTurnExport.init(model:)),
            voiceTags: voiceTags.map(VoiceTagExport.init(model:)),
            voiceRecordings: voiceRecordings.map(VoiceRecordingExport.init(model:)),
            vocalizations: vocalizations.map(VocalizationExport.init(model:))
        )
    }
}

extension AnimalExport {
    init(model: Animal) {
        self.init(id: model.id.uuidString,
                  createdAt: ExportFormatters.timestamp(model.createdAt),
                  name: model.name,
                  species: model.species,
                  colorHex: model.colorHex,
                  photoFilename: model.photoFilename,
                  photoThumbnailFilename: model.photoThumbnailFilename,
                  tracksOutdoorTime: model.tracksOutdoorTime,
                  sortOrder: model.sortOrder,
                  isArchived: model.isArchived,
                  note: model.note)
    }
}

extension ButtonExport {
    init(model: AACButton) {
        self.init(id: model.id.uuidString,
                  createdAt: ExportFormatters.timestamp(model.createdAt),
                  animalId: model.animal?.id.uuidString,
                  label: model.label,
                  colorHex: model.colorHex,
                  sortOrder: model.sortOrder,
                  isArchived: model.isArchived)
    }
}

extension PressExport {
    init(model: Press) {
        self.init(id: model.id.uuidString,
                  createdAt: ExportFormatters.timestamp(model.createdAt),
                  animalId: model.animal?.id.uuidString,
                  buttonId: model.button?.id.uuidString,
                  timestamp: ExportFormatters.timestamp(model.timestamp),
                  kind: model.kindRaw,
                  note: model.note,
                  editedAt: ExportFormatters.optionalTimestamp(model.editedAt))
    }
}

extension FeedDayExport {
    init(model: FeedDay) {
        self.init(id: model.id.uuidString,
                  createdAt: ExportFormatters.timestamp(model.createdAt),
                  animalId: model.animal?.id.uuidString,
                  date: ExportFormatters.day(model.date),
                  outdoorHours: model.outdoorHours,
                  outdoorAreaAcres: model.outdoorAreaAcres,
                  note: model.note)
    }
}

extension FeedingExport {
    init(model: Feeding) {
        self.init(id: model.id.uuidString,
                  createdAt: ExportFormatters.timestamp(model.createdAt),
                  dayId: model.day?.id.uuidString,
                  time: ExportFormatters.timestamp(model.time),
                  note: model.note)
    }
}

extension FeedItemExport {
    init(model: FeedItem) {
        self.init(id: model.id.uuidString,
                  createdAt: ExportFormatters.timestamp(model.createdAt),
                  feedingId: model.feeding?.id.uuidString,
                  category: model.categoryRaw,
                  type: model.type,
                  amount: model.amount,
                  unit: model.unit,
                  sortOrder: model.sortOrder)
    }
}

extension PoopTagExport {
    init(model: PoopTag) {
        self.init(id: model.id.uuidString,
                  createdAt: ExportFormatters.timestamp(model.createdAt),
                  name: model.name,
                  colorHex: model.colorHex,
                  isBuiltIn: model.isBuiltIn,
                  isHidden: model.isHidden,
                  sortOrder: model.sortOrder)
    }
}

extension PoopObservationExport {
    init(model: PoopObservation) {
        let tags = (model.tags ?? [])
            .sorted { ($0.sortOrder, $0.id.uuidString) < ($1.sortOrder, $1.id.uuidString) }
        self.init(id: model.id.uuidString,
                  createdAt: ExportFormatters.timestamp(model.createdAt),
                  animalId: model.animal?.id.uuidString,
                  timestamp: ExportFormatters.timestamp(model.timestamp),
                  tagIds: tags.map { $0.id.uuidString },
                  note: model.note,
                  editedAt: ExportFormatters.optionalTimestamp(model.editedAt))
    }
}

extension HealthCheckInExport {
    init(model: HealthCheckIn) {
        self.init(id: model.id.uuidString,
                  createdAt: ExportFormatters.timestamp(model.createdAt),
                  animalId: model.animal?.id.uuidString,
                  timestamp: ExportFormatters.timestamp(model.timestamp),
                  photoFilename: model.photoFilename,
                  thumbnailFilename: model.thumbnailFilename,
                  videoFilename: model.videoFilename,
                  note: model.note,
                  editedAt: ExportFormatters.optionalTimestamp(model.editedAt))
    }
}

extension OralCheckInExport {
    init(model: OralCheckIn) {
        self.init(id: model.id.uuidString,
                  createdAt: ExportFormatters.timestamp(model.createdAt),
                  animalId: model.animal?.id.uuidString,
                  startedAt: ExportFormatters.timestamp(model.startedAt),
                  endedAt: ExportFormatters.optionalTimestamp(model.endedAt),
                  status: model.statusRaw,
                  model: model.model,
                  inputTokens: model.inputTokens,
                  outputTokens: model.outputTokens,
                  createdRecordIdsJSON: model.createdRecordIdsJSON,
                  errorMessage: model.errorMessage)
    }
}

extension CheckInTurnExport {
    init(model: CheckInTurn) {
        self.init(id: model.id.uuidString,
                  createdAt: ExportFormatters.timestamp(model.createdAt),
                  checkInId: model.checkIn?.id.uuidString,
                  index: model.index,
                  role: model.roleRaw,
                  text: model.text,
                  timestamp: ExportFormatters.timestamp(model.timestamp),
                  draftJSON: model.draftJSON)
    }
}

extension VoiceTagExport {
    init(model: VoiceTag) {
        self.init(id: model.id.uuidString,
                  createdAt: ExportFormatters.timestamp(model.createdAt),
                  kind: model.kindRaw,
                  name: model.name,
                  isBuiltIn: model.isBuiltIn,
                  sortOrder: model.sortOrder)
    }
}

extension VoiceRecordingExport {
    init(model: VoiceRecording) {
        self.init(id: model.id.uuidString,
                  createdAt: ExportFormatters.timestamp(model.createdAt),
                  animalId: model.animal?.id.uuidString,
                  recordedAt: ExportFormatters.timestamp(model.recordedAt),
                  durationS: model.durationS,
                  audioFilename: model.audioFilename,
                  status: model.statusRaw,
                  errorMessage: model.errorMessage,
                  note: model.note,
                  activityTag: model.activityTag,
                  meaningTag: model.meaningTag,
                  userConfidence: model.userConfidence,
                  editedAt: ExportFormatters.optionalTimestamp(model.editedAt))
    }
}

extension VocalizationExport {
    init(model: Vocalization) {
        self.init(id: model.id.uuidString,
                  createdAt: ExportFormatters.timestamp(model.createdAt),
                  recordingId: model.recording?.id.uuidString,
                  startS: model.startS,
                  endS: model.endS,
                  f0Mean: model.f0Mean,
                  f0Min: model.f0Min,
                  f0Max: model.f0Max,
                  f0Slope: model.f0Slope,
                  voicedFraction: model.voicedFraction,
                  rmsDb: model.rmsDb,
                  spectralCentroidHz: model.spectralCentroidHz,
                  mfcc: model.mfcc,
                  activityTag: model.activityTag,
                  meaningTag: model.meaningTag,
                  userConfidence: model.userConfidence,
                  overridden: model.overridden)
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `scripts/test-app.sh`
Expected: 4 more tests than after Task 1, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add App/IO/ExportBundleBuilder.swift AppTests/ExportTestFixtures.swift AppTests/ExportBundleBuilderTests.swift
git commit -m "feat(io): ExportBundleBuilder reads every model into a deterministic value bundle

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: CSVWriter and the presses, poop, and health files

**Files:**
- Create: `App/IO/CSVWriter.swift`, `App/IO/CSVExporter.swift`
- Test: `AppTests/CSVWriterTests.swift`, `AppTests/CSVExporterCoreTests.swift`

**Interfaces:**
- Consumes: `ExportBundle`, `AnimalExport`, `ButtonExport`, `PressExport`, `PoopTagExport`, `PoopObservationExport`, `HealthCheckInExport`, `ExportFormatters` from Task 1.
- Produces: `enum CSVWriter` with `static let lineTerminator = "\n"`, `static func field(_ value: String) -> String`, `static func row(_ fields: [String]) -> String`, `static func document(header: [String], rows: [[String]]) -> String`; `enum CSVExporter` with `static let pressesFilename = "presses.csv"`, `poopFilename = "poop.csv"`, `healthFilename = "health.csv"` and `static func presses(_ bundle: ExportBundle) -> String`, `poop(_ bundle: ExportBundle) -> String`, `health(_ bundle: ExportBundle) -> String`. Task 4 adds `feedings`, `voiceRecordings`, `vocalizations` and `files` to the same `CSVExporter`.

**Tests added: 7.**

- [ ] **Step 1: Write the failing tests**

`AppTests/CSVWriterTests.swift`:
```swift
import XCTest
@testable import AnimalTracker

final class CSVWriterTests: XCTestCase {
    func testPlainFieldsAreNotQuoted() {
        XCTAssertEqual(CSVWriter.field("hay"), "hay")
        XCTAssertEqual(CSVWriter.field(""), "")
        XCTAssertEqual(CSVWriter.field("waiting at door"), "waiting at door")
        XCTAssertEqual(CSVWriter.row(["a", "b", "c"]), "a,b,c")
    }

    func testQuotesCommasQuotesAndNewlines() {
        XCTAssertEqual(CSVWriter.field("a,b"), "\"a,b\"")
        XCTAssertEqual(CSVWriter.field("say \"hi\""), "\"say \"\"hi\"\"\"")
        XCTAssertEqual(CSVWriter.field("line1\nline2"), "\"line1\nline2\"")
        XCTAssertEqual(CSVWriter.field("line1\r\nline2"), "\"line1\r\nline2\"")
        XCTAssertEqual(CSVWriter.row(["x", "a,b", "c\"d"]), "x,\"a,b\",\"c\"\"d\"")
    }

    func testDocumentIsHeaderThenRowsWithATrailingNewline() {
        XCTAssertEqual(CSVWriter.document(header: ["a", "b"], rows: [["1", "2"], ["3", "4"]]), "a,b\n1,2\n3,4\n")
        XCTAssertEqual(CSVWriter.document(header: ["a"], rows: []), "a\n")
    }
}
```

`AppTests/CSVExporterCoreTests.swift`:
```swift
import XCTest
@testable import AnimalTracker

final class CSVExporterCoreTests: XCTestCase {
    private func sample() -> ExportBundle {
        ExportBundle(
            animals: [AnimalExport(id: "A1", name: "Juniper")],
            buttons: [ButtonExport(id: "B1", animalId: "A1", label: "Out")],
            presses: [PressExport(id: "P1", animalId: "A1", buttonId: "B1",
                                  timestamp: "2026-09-18T08:00:00-07:00", kind: "spontaneous",
                                  note: "hard, twice \"again\"")],
            poopTags: [PoopTagExport(id: "T1", name: "normal"), PoopTagExport(id: "T2", name: "soft")],
            poopObservations: [PoopObservationExport(id: "O1", animalId: "A1",
                                                     timestamp: "2026-09-18T09:00:00-07:00",
                                                     tagIds: ["T1", "T2"])],
            healthCheckIns: [HealthCheckInExport(id: "H1", animalId: "A1",
                                                 timestamp: "2026-09-18T10:00:00-07:00",
                                                 photoFilename: "bbb-photo.jpg", note: "fine")]
        )
    }

    func testPressesHeaderAndQuotedNote() {
        let lines = CSVExporter.presses(sample()).components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "animal,timestamp_iso8601,button,kind,note")
        XCTAssertEqual(lines[1], "Juniper,2026-09-18T08:00:00-07:00,Out,spontaneous,\"hard, twice \"\"again\"\"\"")
        XCTAssertEqual(lines[2], "")
    }

    func testPoopHeaderAndPipeSeparatedTags() {
        let lines = CSVExporter.poop(sample()).components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "animal,timestamp_iso8601,tags,note")
        XCTAssertEqual(lines[1], "Juniper,2026-09-18T09:00:00-07:00,normal|soft,")
    }

    func testHealthHeaderAndEmptyVideoColumn() {
        let lines = CSVExporter.health(sample()).components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "animal,timestamp_iso8601,photo_filename,video_filename,note")
        XCTAssertEqual(lines[1], "Juniper,2026-09-18T10:00:00-07:00,bbb-photo.jpg,,fine")
    }

    func testEmptyBundleStillWritesTheHeaderLine() {
        XCTAssertEqual(CSVExporter.presses(ExportBundle()), "animal,timestamp_iso8601,button,kind,note\n")
        XCTAssertEqual(CSVExporter.poop(ExportBundle()), "animal,timestamp_iso8601,tags,note\n")
        XCTAssertEqual(CSVExporter.health(ExportBundle()),
                       "animal,timestamp_iso8601,photo_filename,video_filename,note\n")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test-app.sh`
Expected: build errors, `CSVWriter` and `CSVExporter` not found.

- [ ] **Step 3: Implement**

`App/IO/CSVWriter.swift`:
```swift
import Foundation

/// RFC 4180 field quoting. Records are separated by a single newline and the document ends with one.
enum CSVWriter {
    static let lineTerminator = "\n"

    /// A field containing a comma, a double quote, CR or LF is wrapped in double quotes,
    /// and every inner double quote is doubled.
    static func field(_ value: String) -> String {
        let needsQuoting = value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r")
        guard needsQuoting else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func row(_ fields: [String]) -> String {
        fields.map(field).joined(separator: ",")
    }

    static func document(header: [String], rows: [[String]]) -> String {
        ([row(header)] + rows.map(row)).joined(separator: lineTerminator) + lineTerminator
    }
}
```

`App/IO/CSVExporter.swift`:
```swift
import Foundation

/// The spec's CSV files, as pure functions over an ExportBundle. Every row carries the animal name
/// because one export covers all animals. Headers and column order come straight from the spec.
enum CSVExporter {
    static let pressesFilename = "presses.csv"
    static let poopFilename = "poop.csv"
    static let healthFilename = "health.csv"

    static func presses(_ bundle: ExportBundle) -> String {
        let names = animalNames(bundle)
        let labels = Dictionary(bundle.buttons.map { ($0.id, $0.label) }, uniquingKeysWith: { first, _ in first })
        let rows = bundle.presses.map { press in
            [names[press.animalId ?? ""] ?? "",
             press.timestamp,
             labels[press.buttonId ?? ""] ?? "",
             press.kind,
             ExportFormatters.text(press.note)]
        }
        return CSVWriter.document(header: ["animal", "timestamp_iso8601", "button", "kind", "note"], rows: rows)
    }

    static func poop(_ bundle: ExportBundle) -> String {
        let names = animalNames(bundle)
        let tagNames = Dictionary(bundle.poopTags.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let rows = bundle.poopObservations.map { observation in
            [names[observation.animalId ?? ""] ?? "",
             observation.timestamp,
             observation.tagIds.compactMap { tagNames[$0] }.joined(separator: "|"),
             ExportFormatters.text(observation.note)]
        }
        return CSVWriter.document(header: ["animal", "timestamp_iso8601", "tags", "note"], rows: rows)
    }

    static func health(_ bundle: ExportBundle) -> String {
        let names = animalNames(bundle)
        let rows = bundle.healthCheckIns.map { checkIn in
            [names[checkIn.animalId ?? ""] ?? "",
             checkIn.timestamp,
             ExportFormatters.text(checkIn.photoFilename),
             ExportFormatters.text(checkIn.videoFilename),
             ExportFormatters.text(checkIn.note)]
        }
        return CSVWriter.document(header: ["animal", "timestamp_iso8601", "photo_filename", "video_filename", "note"],
                                  rows: rows)
    }

    static func animalNames(_ bundle: ExportBundle) -> [String: String] {
        Dictionary(bundle.animals.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `scripts/test-app.sh`
Expected: 7 more tests than after Task 2, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add App/IO/CSVWriter.swift App/IO/CSVExporter.swift AppTests/CSVWriterTests.swift AppTests/CSVExporterCoreTests.swift
git commit -m "feat(io): RFC 4180 CSV writer plus presses, poop, and health exports

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: The feedings, voice-recordings, and vocalizations files

**Files:**
- Modify: `App/IO/CSVExporter.swift` (add three documents and the file list)
- Test: `AppTests/CSVExporterFeedTests.swift`, `AppTests/CSVExporterVoiceTests.swift`

**Interfaces:**
- Consumes: `CSVWriter.document(header:rows:)`, `CSVExporter.animalNames(_:)`, `ExportFormatters.decimal/integer/text/flag`, and the export structs.
- Produces: on `CSVExporter`, `static let feedingsFilename = "feedings.csv"`, `voiceRecordingsFilename = "voice-recordings.csv"`, `vocalizationsFilename = "vocalizations.csv"`; `static func feedings(_ bundle: ExportBundle) -> String`, `voiceRecordings(_ bundle: ExportBundle) -> String`, `vocalizations(_ bundle: ExportBundle) -> String`, and `static func files(_ bundle: ExportBundle) -> [(name: String, contents: String)]` returning the six CSVs in spec order.

**Tests added: 7.**

- [ ] **Step 1: Write the failing tests**

`AppTests/CSVExporterFeedTests.swift`:
```swift
import XCTest
@testable import AnimalTracker

final class CSVExporterFeedTests: XCTestCase {
    private func sample() -> ExportBundle {
        ExportBundle(
            animals: [AnimalExport(id: "A1", name: "Juniper")],
            feedDays: [FeedDayExport(id: "D1", animalId: "A1", date: "2026-09-18",
                                     outdoorHours: 6.5, outdoorAreaAcres: 2, note: "windy")],
            feedings: [FeedingExport(id: "F1", dayId: "D1", time: "2026-09-18T07:00:00-07:00",
                                     note: "morning, early"),
                       FeedingExport(id: "F2", dayId: "D1", time: "2026-09-18T18:00:00-07:00")],
            feedItems: [FeedItemExport(id: "I1", feedingId: "F1", category: "forage", type: "hay",
                                       amount: 2, unit: "flakes", sortOrder: 0),
                        FeedItemExport(id: "I2", feedingId: "F1", category: "supplement", type: "MSM",
                                       amount: 1, unit: "scoop", sortOrder: 1)]
        )
    }

    func testFeedingsHeaderMatchesTheSpec() {
        XCTAssertEqual(CSVExporter.feedings(sample()).components(separatedBy: "\n")[0],
                       "animal,date,outdoor_hours,outdoor_area_acres,feeding_time_iso8601,category,type,amount,unit,feeding_note")
    }

    func testOneRowPerFeedItem() {
        let lines = CSVExporter.feedings(sample()).components(separatedBy: "\n")
        XCTAssertEqual(lines[1],
                       "Juniper,2026-09-18,6.5,2.0,2026-09-18T07:00:00-07:00,forage,hay,2.0,flakes,\"morning, early\"")
        XCTAssertEqual(lines[2],
                       "Juniper,2026-09-18,6.5,2.0,2026-09-18T07:00:00-07:00,supplement,MSM,1.0,scoop,\"morning, early\"")
    }

    func testFeedingWithNoItemsProducesOneRowWithEmptyItemColumns() {
        let lines = CSVExporter.feedings(sample()).components(separatedBy: "\n")
        XCTAssertEqual(lines[3], "Juniper,2026-09-18,6.5,2.0,2026-09-18T18:00:00-07:00,,,,,")
        XCTAssertEqual(lines[4], "")
    }
}
```

`AppTests/CSVExporterVoiceTests.swift`:
```swift
import XCTest
@testable import AnimalTracker

final class CSVExporterVoiceTests: XCTestCase {
    private func sample() -> ExportBundle {
        ExportBundle(
            animals: [AnimalExport(id: "A1", name: "Juniper")],
            voiceRecordings: [VoiceRecordingExport(id: "R1", animalId: "A1",
                                                   recordedAt: "2026-09-18T11:00:00-07:00",
                                                   durationS: 12.5, audioFilename: "ccc-audio.m4a",
                                                   status: "analyzed", note: "at the gate",
                                                   activityTag: "waiting at door", meaningTag: "hungry",
                                                   userConfidence: 2)],
            vocalizations: [VocalizationExport(id: "V1", recordingId: "R1", startS: 0.5, endS: 1.25,
                                               f0Mean: 420.5, f0Min: 380, f0Max: 470, f0Slope: -12.5,
                                               voicedFraction: 0.8, rmsDb: -22.5, spectralCentroidHz: 1800,
                                               mfcc: Array(repeating: 0.5, count: 13),
                                               meaningTag: "hungry", userConfidence: 2, overridden: true),
                            VocalizationExport(id: "V2", recordingId: "R1", startS: 2, endS: 2.4,
                                               voicedFraction: 0, rmsDb: -48, spectralCentroidHz: 900,
                                               mfcc: [])]
        )
    }

    func testVoiceRecordingsHeaderAndRow() {
        let lines = CSVExporter.voiceRecordings(sample()).components(separatedBy: "\n")
        XCTAssertEqual(lines[0],
                       "animal,timestamp_iso8601,duration_s,audio_filename,status,activity,meaning,confidence,note")
        XCTAssertEqual(lines[1],
                       "Juniper,2026-09-18T11:00:00-07:00,12.5,ccc-audio.m4a,analyzed,waiting at door,hungry,2,at the gate")
    }

    func testVocalizationsHeaderHasMfcc0ThroughMfcc12() {
        let header = CSVExporter.vocalizations(sample()).components(separatedBy: "\n")[0]
        XCTAssertEqual(header,
                       "animal,recording_id,start_s,end_s,f0_mean,f0_min,f0_max,f0_slope,voiced_fraction,rms_db,spectral_centroid_hz,mfcc0,mfcc1,mfcc2,mfcc3,mfcc4,mfcc5,mfcc6,mfcc7,mfcc8,mfcc9,mfcc10,mfcc11,mfcc12,activity,meaning,confidence,overridden")
        XCTAssertEqual(header.components(separatedBy: ",").count, 28)
    }

    func testVocalizationRowsBlankMissingPitchAndMissingCoefficients() {
        let lines = CSVExporter.vocalizations(sample()).components(separatedBy: "\n")
        XCTAssertEqual(lines[1],
                       "Juniper,R1,0.5,1.25,420.5,380.0,470.0,-12.5,0.8,-22.5,1800.0,"
                       + Array(repeating: "0.5", count: 13).joined(separator: ",")
                       + ",,hungry,2,true")
        XCTAssertEqual(lines[2],
                       "Juniper,R1,2.0,2.4,,,,,0.0,-48.0,900.0,"
                       + Array(repeating: "", count: 13).joined(separator: ",")
                       + ",,,,false")
    }

    func testFilesAreTheSixSpecCSVsInOrder() {
        XCTAssertEqual(CSVExporter.files(ExportBundle()).map { $0.name },
                       ["presses.csv", "feedings.csv", "poop.csv", "health.csv",
                        "voice-recordings.csv", "vocalizations.csv"])
        XCTAssertEqual(CSVExporter.files(ExportBundle()).map { $0.contents.components(separatedBy: "\n").count },
                       [2, 2, 2, 2, 2, 2])
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test-app.sh`
Expected: build errors, `CSVExporter.feedings`, `voiceRecordings`, `vocalizations`, `files` not found.

- [ ] **Step 3: Implement**

Append to `App/IO/CSVExporter.swift`, inside the `enum CSVExporter` body, after `healthFilename`:
```swift
    static let feedingsFilename = "feedings.csv"
    static let voiceRecordingsFilename = "voice-recordings.csv"
    static let vocalizationsFilename = "vocalizations.csv"

    /// The six CSV documents in the order the spec lists them.
    static func files(_ bundle: ExportBundle) -> [(name: String, contents: String)] {
        [(pressesFilename, presses(bundle)),
         (feedingsFilename, feedings(bundle)),
         (poopFilename, poop(bundle)),
         (healthFilename, health(bundle)),
         (voiceRecordingsFilename, voiceRecordings(bundle)),
         (vocalizationsFilename, vocalizations(bundle))]
    }

    /// One row per FeedItem. A feeding with no items still gets one row, with the four item columns empty.
    static func feedings(_ bundle: ExportBundle) -> String {
        let names = animalNames(bundle)
        var itemsByFeeding: [String: [FeedItemExport]] = [:]
        for item in bundle.feedItems {
            guard let feedingId = item.feedingId else { continue }
            itemsByFeeding[feedingId, default: []].append(item)
        }
        var feedingsByDay: [String: [FeedingExport]] = [:]
        for feeding in bundle.feedings {
            guard let dayId = feeding.dayId else { continue }
            feedingsByDay[dayId, default: []].append(feeding)
        }
        var rows: [[String]] = []
        for day in bundle.feedDays {
            let prefix = [names[day.animalId ?? ""] ?? "",
                          day.date,
                          ExportFormatters.decimal(day.outdoorHours),
                          ExportFormatters.decimal(day.outdoorAreaAcres)]
            for feeding in feedingsByDay[day.id] ?? [] {
                let note = ExportFormatters.text(feeding.note)
                let items = itemsByFeeding[feeding.id] ?? []
                if items.isEmpty {
                    rows.append(prefix + [feeding.time, "", "", "", "", note])
                } else {
                    for item in items {
                        rows.append(prefix + [feeding.time,
                                              item.category,
                                              item.type,
                                              ExportFormatters.decimal(item.amount),
                                              item.unit,
                                              note])
                    }
                }
            }
        }
        return CSVWriter.document(header: ["animal", "date", "outdoor_hours", "outdoor_area_acres",
                                           "feeding_time_iso8601", "category", "type", "amount", "unit",
                                           "feeding_note"],
                                  rows: rows)
    }

    static func voiceRecordings(_ bundle: ExportBundle) -> String {
        let names = animalNames(bundle)
        let rows = bundle.voiceRecordings.map { recording in
            [names[recording.animalId ?? ""] ?? "",
             recording.recordedAt,
             ExportFormatters.decimal(recording.durationS),
             recording.audioFilename,
             recording.status,
             ExportFormatters.text(recording.activityTag),
             ExportFormatters.text(recording.meaningTag),
             ExportFormatters.integer(recording.userConfidence),
             recording.note]
        }
        return CSVWriter.document(header: ["animal", "timestamp_iso8601", "duration_s", "audio_filename",
                                           "status", "activity", "meaning", "confidence", "note"],
                                  rows: rows)
    }

    static func vocalizations(_ bundle: ExportBundle) -> String {
        let names = animalNames(bundle)
        let recordings = Dictionary(bundle.voiceRecordings.map { ($0.id, $0) },
                                    uniquingKeysWith: { first, _ in first })
        let header = ["animal", "recording_id", "start_s", "end_s", "f0_mean", "f0_min", "f0_max",
                      "f0_slope", "voiced_fraction", "rms_db", "spectral_centroid_hz"]
            + (0..<13).map { "mfcc\($0)" }
            + ["activity", "meaning", "confidence", "overridden"]
        let rows = bundle.vocalizations.map { vocalization -> [String] in
            let recording = recordings[vocalization.recordingId ?? ""]
            let coefficients = (0..<13).map { index -> String in
                index < vocalization.mfcc.count ? ExportFormatters.decimal(vocalization.mfcc[index]) : ""
            }
            return [names[recording?.animalId ?? ""] ?? "",
                    ExportFormatters.text(vocalization.recordingId),
                    ExportFormatters.decimal(vocalization.startS),
                    ExportFormatters.decimal(vocalization.endS),
                    ExportFormatters.decimal(vocalization.f0Mean),
                    ExportFormatters.decimal(vocalization.f0Min),
                    ExportFormatters.decimal(vocalization.f0Max),
                    ExportFormatters.decimal(vocalization.f0Slope),
                    ExportFormatters.decimal(vocalization.voicedFraction),
                    ExportFormatters.decimal(vocalization.rmsDb),
                    ExportFormatters.decimal(vocalization.spectralCentroidHz)]
                + coefficients
                + [ExportFormatters.text(vocalization.activityTag),
                   ExportFormatters.text(vocalization.meaningTag),
                   ExportFormatters.integer(vocalization.userConfidence),
                   ExportFormatters.flag(vocalization.overridden)]
        }
        return CSVWriter.document(header: header, rows: rows)
    }
```

- [ ] **Step 4: Run to verify pass**

Run: `scripts/test-app.sh`
Expected: 7 more tests than after Task 3, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add App/IO/CSVExporter.swift AppTests/CSVExporterFeedTests.swift AppTests/CSVExporterVoiceTests.swift
git commit -m "feat(io): feedings, voice-recordings, and vocalizations CSV exports

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: JSONExporter

**Files:**
- Create: `App/IO/JSONExporter.swift`
- Test: `AppTests/JSONExporterTests.swift`

**Interfaces:**
- Consumes: `ExportBundle` from Task 1, `ExportBundleBuilder.build(context:)` and `ExportTestFixtures` from Task 2.
- Produces: `enum JSONExporter` with `static let filename = "animal-tracker.json"`, `static func encoder() -> JSONEncoder`, `static func data(_ bundle: ExportBundle) throws -> Data`, `static func string(_ bundle: ExportBundle) throws -> String`.

**Tests added: 5.**

- [ ] **Step 1: Write the failing tests**

`AppTests/JSONExporterTests.swift`:
```swift
import XCTest
@testable import AnimalTracker

@MainActor
final class JSONExporterTests: XCTestCase {
    private func populatedBundle() throws -> ExportBundle {
        try ExportBundleBuilder.build(context: ExportTestFixtures.populatedContainer().mainContext)
    }

    func testTopLevelKeysAndVersionMatchTheSpec() throws {
        let data = try JSONExporter.data(ExportBundle())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys),
                       ["version", "animals", "buttons", "presses", "feedDays", "feedings", "feedItems",
                        "poopTags", "poopObservations", "healthCheckIns", "oralCheckIns", "checkInTurns",
                        "voiceTags", "voiceRecordings", "vocalizations"])
        XCTAssertEqual(object["version"] as? Int, 4)
        XCTAssertEqual(JSONExporter.filename, "animal-tracker.json")
    }

    func testIdsAreUUIDStringsAndRelationshipsAreIds() throws {
        let data = try JSONExporter.data(try populatedBundle())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let press = try XCTUnwrap((object["presses"] as? [[String: Any]])?.first)
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(press["id"] as? String)))
        XCTAssertEqual(press["buttonId"] as? String, ExportTestFixtures.id(2).uuidString)
        XCTAssertEqual(press["animalId"] as? String, ExportTestFixtures.id(1).uuidString)
        let vocalization = try XCTUnwrap((object["vocalizations"] as? [[String: Any]])?.first)
        XCTAssertEqual(vocalization["recordingId"] as? String, ExportTestFixtures.id(15).uuidString)
        XCTAssertEqual((vocalization["mfcc"] as? [Double])?.count, 13)
        let observation = try XCTUnwrap((object["poopObservations"] as? [[String: Any]])?.first)
        XCTAssertEqual(observation["tagIds"] as? [String],
                       [ExportTestFixtures.id(8).uuidString, ExportTestFixtures.id(9).uuidString])
    }

    func testMediaIsReferencedByFilenameOnly() throws {
        let text = try JSONExporter.string(try populatedBundle())
        XCTAssertTrue(text.contains("\"ccc-audio.m4a\""))
        XCTAssertTrue(text.contains("\"bbb-photo.jpg\""))
        XCTAssertFalse(text.contains("Documents/Media"))
        XCTAssertFalse(text.contains("base64"))
        XCTAssertFalse(text.contains("anthropic-api-key"))
    }

    func testTimestampsAreISO8601WithoutFractionalSeconds() throws {
        let data = try JSONExporter.data(try populatedBundle())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let press = try XCTUnwrap((object["presses"] as? [[String: Any]])?.first)
        let timestamp = try XCTUnwrap(press["timestamp"] as? String)
        let pattern = "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}([+-]\\d{2}:\\d{2}|Z)$"
        XCTAssertNotNil(timestamp.range(of: pattern, options: .regularExpression), timestamp)
        let day = try XCTUnwrap((object["feedDays"] as? [[String: Any]])?.first)
        XCTAssertNotNil((day["date"] as? String)?.range(of: "^\\d{4}-\\d{2}-\\d{2}$", options: .regularExpression))
    }

    func testEncodingTheSameBundleTwiceGivesTheSameBytes() throws {
        let bundle = try populatedBundle()
        XCTAssertEqual(try JSONExporter.data(bundle), try JSONExporter.data(bundle))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test-app.sh`
Expected: build error, `JSONExporter` not found.

- [ ] **Step 3: Implement**

`App/IO/JSONExporter.swift`:
```swift
import Foundation

/// animal-tracker.json, version 4. Keys are sorted so two exports of the same store are byte-identical
/// and a reviewer can diff them. Media is referenced by filename; the files themselves stay in Documents/Media.
enum JSONExporter {
    static let filename = "animal-tracker.json"

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func data(_ bundle: ExportBundle) throws -> Data {
        try encoder().encode(bundle)
    }

    static func string(_ bundle: ExportBundle) throws -> String {
        String(decoding: try data(bundle), as: UTF8.self)
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `scripts/test-app.sh`
Expected: 5 more tests than after Task 4, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add App/IO/JSONExporter.swift AppTests/JSONExporterTests.swift
git commit -m "feat(io): deterministic animal-tracker.json export at version 4

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: Import decoding, version check, and dangling-reference validation

**Files:**
- Create: `App/IO/JSONImporter.swift`
- Test: `AppTests/JSONImportValidationTests.swift`

**Interfaces:**
- Consumes: `ExportBundle` and the export structs from Task 1, `JSONExporter.data(_:)` from Task 5, `ExportTestFixtures` and `ExportBundleBuilder` from Task 2.
- Produces: `enum ImportError: LocalizedError, Equatable` with cases `malformedJSON(String)`, `unsupportedVersion(found: Int)`, `danglingReference(String)` and an `errorDescription`; `enum EntityNames` with the fourteen display names and `static let all: [String]`; `struct ImportCounts: Equatable` with `entries: [Entry]`, `Entry(entity:inserted:updated:)`, `totalInserted`, `totalUpdated`, `lines: [String]`; `enum JSONImporter` with `static func decode(_ data: Data) throws -> ExportBundle` and `static func validate(_ bundle: ExportBundle) throws`. Task 7 adds `preview` and `merge` to the same enum.

**Tests added: 10.**

- [ ] **Step 1: Write the failing tests**

`AppTests/JSONImportValidationTests.swift`:
```swift
import XCTest
@testable import AnimalTracker

@MainActor
final class JSONImportValidationTests: XCTestCase {
    private let absent = "99999999-9999-9999-9999-999999999999"

    private func validBundle() throws -> ExportBundle {
        try ExportBundleBuilder.build(context: ExportTestFixtures.populatedContainer().mainContext)
    }

    private func bytes(_ bundle: ExportBundle) throws -> Data {
        try JSONExporter.data(bundle)
    }

    private func assertDangling(_ bundle: ExportBundle, mentions words: [String],
                                file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertThrowsError(try JSONImporter.decode(try bytes(bundle)), file: file, line: line) { error in
            guard case .danglingReference(let detail)? = error as? ImportError else {
                return XCTFail("expected a dangling reference, got \(error)", file: file, line: line)
            }
            for word in words {
                XCTAssertTrue(detail.contains(word), "\(detail) does not name \(word)", file: file, line: line)
            }
        }
    }

    func testAcceptsAValidBundle() throws {
        let bundle = try validBundle()
        XCTAssertEqual(try JSONImporter.decode(try bytes(bundle)), bundle)
    }

    func testRejectsUnknownVersion() throws {
        var bundle = try validBundle()
        bundle.version = 3
        XCTAssertThrowsError(try JSONImporter.decode(try bytes(bundle))) { error in
            XCTAssertEqual(error as? ImportError, .unsupportedVersion(found: 3))
            XCTAssertTrue((error as? ImportError)?.errorDescription?.contains("version 3") ?? false)
        }
    }

    func testRejectsMalformedJSON() {
        XCTAssertThrowsError(try JSONImporter.decode(Data("not json at all".utf8))) { error in
            switch error as? ImportError {
            case .malformedJSON: break
            default: XCTFail("expected malformedJSON, got \(error)")
            }
        }
    }

    func testRejectsRecordWithMissingAnimal() throws {
        var bundle = try validBundle()
        bundle.healthCheckIns[0].animalId = absent
        try assertDangling(bundle, mentions: ["health check-in", "animal", absent])
    }

    func testRejectsPressWithMissingButton() throws {
        var bundle = try validBundle()
        bundle.presses[0].buttonId = absent
        try assertDangling(bundle, mentions: ["press", "button", absent])
    }

    func testRejectsFeedItemWithMissingFeeding() throws {
        var bundle = try validBundle()
        bundle.feedItems[0].feedingId = absent
        try assertDangling(bundle, mentions: ["feed item", "feeding", absent])
    }

    func testRejectsFeedingWithMissingFeedDay() throws {
        var bundle = try validBundle()
        bundle.feedings[0].dayId = absent
        try assertDangling(bundle, mentions: ["feeding", "feed day", absent])
    }

    func testRejectsObservationWithMissingTag() throws {
        var bundle = try validBundle()
        bundle.poopObservations[0].tagIds = [absent]
        try assertDangling(bundle, mentions: ["poop observation", "tag", absent])
    }

    func testRejectsVocalizationWithMissingRecording() throws {
        var bundle = try validBundle()
        bundle.vocalizations[0].recordingId = absent
        try assertDangling(bundle, mentions: ["vocalization", "voice recording", absent])
    }

    func testRejectsTurnWithMissingCheckIn() throws {
        var bundle = try validBundle()
        bundle.checkInTurns[0].checkInId = absent
        try assertDangling(bundle, mentions: ["check-in turn", "oral check-in", absent])
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test-app.sh`
Expected: build errors, `ImportError` and `JSONImporter` not found.

- [ ] **Step 3: Implement**

`App/IO/JSONImporter.swift`:
```swift
import Foundation
import SwiftData

/// Everything an import can refuse, with a message that names the problem.
enum ImportError: LocalizedError, Equatable {
    case malformedJSON(String)
    case unsupportedVersion(found: Int)
    case danglingReference(String)

    var errorDescription: String? {
        switch self {
        case .malformedJSON(let detail):
            return "This is not an AnimalTracker export: \(detail)"
        case .unsupportedVersion(let found):
            return "This file is export version \(found). AnimalTracker imports version \(ExportBundle.currentVersion)."
        case .danglingReference(let detail):
            return "This file is incomplete: \(detail)."
        }
    }
}

/// Display names for the confirmation sheet, in a fixed order.
enum EntityNames {
    static let animals = "Animals"
    static let buttons = "Buttons"
    static let presses = "Presses"
    static let feedDays = "Feed days"
    static let feedings = "Feedings"
    static let feedItems = "Feed items"
    static let poopTags = "Poop tags"
    static let poopObservations = "Poop observations"
    static let healthCheckIns = "Health check-ins"
    static let oralCheckIns = "Oral check-ins"
    static let checkInTurns = "Check-in turns"
    static let voiceTags = "Voice tags"
    static let voiceRecordings = "Voice recordings"
    static let vocalizations = "Vocalizations"

    static let all = [animals, buttons, presses, feedDays, feedings, feedItems, poopTags,
                      poopObservations, healthCheckIns, oralCheckIns, checkInTurns, voiceTags,
                      voiceRecordings, vocalizations]
}

/// What an import would do, or did do, per entity.
struct ImportCounts: Equatable {
    struct Entry: Equatable, Identifiable {
        let entity: String
        let inserted: Int
        let updated: Int
        var id: String { entity }
        var total: Int { inserted + updated }
    }

    let entries: [Entry]

    var totalInserted: Int { entries.reduce(0) { $0 + $1.inserted } }
    var totalUpdated: Int { entries.reduce(0) { $0 + $1.updated } }

    /// One line per entity that has anything in it, for the confirmation alert.
    var lines: [String] {
        entries.filter { $0.total > 0 }.map { "\($0.entity): \($0.inserted) new, \($0.updated) updated" }
    }
}

private struct VersionProbe: Decodable {
    let version: Int
}

enum JSONImporter {
    /// Parses the file, refuses an unknown version, then refuses any reference that points at a record
    /// the file does not contain.
    static func decode(_ data: Data) throws -> ExportBundle {
        let decoder = JSONDecoder()
        let probe: VersionProbe
        do {
            probe = try decoder.decode(VersionProbe.self, from: data)
        } catch {
            throw ImportError.malformedJSON("it has no \"version\" number at the top level")
        }
        guard probe.version == ExportBundle.currentVersion else {
            throw ImportError.unsupportedVersion(found: probe.version)
        }
        let bundle: ExportBundle
        do {
            bundle = try decoder.decode(ExportBundle.self, from: data)
        } catch {
            throw ImportError.malformedJSON(String(describing: error))
        }
        try validate(bundle)
        return bundle
    }

    static func validate(_ bundle: ExportBundle) throws {
        let animals = Set(bundle.animals.map(\.id))
        let buttons = Set(bundle.buttons.map(\.id))
        let feedDays = Set(bundle.feedDays.map(\.id))
        let feedings = Set(bundle.feedings.map(\.id))
        let poopTags = Set(bundle.poopTags.map(\.id))
        let oralCheckIns = Set(bundle.oralCheckIns.map(\.id))
        let voiceRecordings = Set(bundle.voiceRecordings.map(\.id))

        func require(_ referenced: String?, in known: Set<String>,
                     owner: String, ownerID: String, target: String) throws {
            guard let referenced else { return }
            guard known.contains(referenced) else {
                throw ImportError.danglingReference(
                    "\(owner) \(ownerID) refers to \(target) \(referenced), which is not in the file")
            }
        }

        for button in bundle.buttons {
            try require(button.animalId, in: animals, owner: "button", ownerID: button.id, target: "animal")
        }
        for press in bundle.presses {
            try require(press.animalId, in: animals, owner: "press", ownerID: press.id, target: "animal")
            try require(press.buttonId, in: buttons, owner: "press", ownerID: press.id, target: "button")
        }
        for day in bundle.feedDays {
            try require(day.animalId, in: animals, owner: "feed day", ownerID: day.id, target: "animal")
        }
        for feeding in bundle.feedings {
            try require(feeding.dayId, in: feedDays, owner: "feeding", ownerID: feeding.id, target: "feed day")
        }
        for item in bundle.feedItems {
            try require(item.feedingId, in: feedings, owner: "feed item", ownerID: item.id, target: "feeding")
        }
        for observation in bundle.poopObservations {
            try require(observation.animalId, in: animals,
                        owner: "poop observation", ownerID: observation.id, target: "animal")
            for tagID in observation.tagIds {
                try require(tagID, in: poopTags,
                            owner: "poop observation", ownerID: observation.id, target: "tag")
            }
        }
        for checkIn in bundle.healthCheckIns {
            try require(checkIn.animalId, in: animals,
                        owner: "health check-in", ownerID: checkIn.id, target: "animal")
        }
        for checkIn in bundle.oralCheckIns {
            try require(checkIn.animalId, in: animals,
                        owner: "oral check-in", ownerID: checkIn.id, target: "animal")
        }
        for turn in bundle.checkInTurns {
            try require(turn.checkInId, in: oralCheckIns,
                        owner: "check-in turn", ownerID: turn.id, target: "oral check-in")
        }
        for recording in bundle.voiceRecordings {
            try require(recording.animalId, in: animals,
                        owner: "voice recording", ownerID: recording.id, target: "animal")
        }
        for vocalization in bundle.vocalizations {
            try require(vocalization.recordingId, in: voiceRecordings,
                        owner: "vocalization", ownerID: vocalization.id, target: "voice recording")
        }
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `scripts/test-app.sh`
Expected: 10 more tests than after Task 5, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add App/IO/JSONImporter.swift AppTests/JSONImportValidationTests.swift
git commit -m "feat(io): import decoding with version and dangling-reference checks that name the problem

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: Merge by id, counts per entity, and the JSON round trip

**Files:**
- Modify: `App/IO/JSONImporter.swift` (add `preview` and `merge`)
- Test: `AppTests/JSONImporterMergeTests.swift`, `AppTests/JSONRoundTripTests.swift`

**Interfaces:**
- Consumes: `ImportCounts`, `EntityNames`, `JSONImporter.decode(_:)` from Task 6; `ExportBundleBuilder.build(context:)` from Task 2; `JSONExporter.data(_:)` from Task 5; `TestSupport.container()` from Plan A.
- Produces: on `JSONImporter`, `static func preview(_ bundle: ExportBundle, context: ModelContext) throws -> ImportCounts` which changes nothing, and `@discardableResult static func merge(_ bundle: ExportBundle, context: ModelContext) throws -> ImportCounts` which updates or inserts every record by id and calls `context.save()` exactly once.

**Tests added: 6.**

- [ ] **Step 1: Write the failing tests**

`AppTests/JSONImporterMergeTests.swift`:
```swift
import SwiftData
import XCTest
@testable import AnimalTracker

@MainActor
final class JSONImporterMergeTests: XCTestCase {
    private func sourceBundle() throws -> ExportBundle {
        try ExportBundleBuilder.build(context: ExportTestFixtures.populatedContainer().mainContext)
    }

    private func recordCount(_ bundle: ExportBundle) -> Int {
        bundle.animals.count + bundle.buttons.count + bundle.presses.count + bundle.feedDays.count
            + bundle.feedings.count + bundle.feedItems.count + bundle.poopTags.count
            + bundle.poopObservations.count + bundle.healthCheckIns.count + bundle.oralCheckIns.count
            + bundle.checkInTurns.count + bundle.voiceTags.count + bundle.voiceRecordings.count
            + bundle.vocalizations.count
    }

    func testInsertsEverythingIntoAnEmptyContainer() throws {
        let bundle = try sourceBundle()
        let target = try TestSupport.container()
        let counts = try JSONImporter.merge(bundle, context: target.mainContext)
        XCTAssertEqual(counts.totalUpdated, 0)
        XCTAssertEqual(counts.totalInserted, recordCount(bundle))
        XCTAssertEqual(counts.entries.map(\.entity), EntityNames.all)
        XCTAssertEqual(try target.mainContext.fetch(FetchDescriptor<Animal>()).count, 2)
        XCTAssertEqual(try target.mainContext.fetch(FetchDescriptor<Vocalization>()).count, 2)
    }

    func testUpdatesExistingByIdAndInsertsOnlyWhatIsNew() throws {
        let bundle = try sourceBundle()
        let target = try ExportTestFixtures.populatedContainer()
        var second = bundle
        second.animals[0].name = "Juniper II"
        var extraPress = second.presses[0]
        extraPress.id = "22222222-2222-2222-2222-222222222222"
        second.presses.append(extraPress)
        let counts = try JSONImporter.merge(second, context: target.mainContext)
        XCTAssertEqual(counts.totalInserted, 1)
        XCTAssertEqual(counts.totalUpdated, recordCount(bundle))
        let animals = try target.mainContext.fetch(FetchDescriptor<Animal>())
        XCTAssertEqual(animals.first { $0.id == ExportTestFixtures.id(1) }?.name, "Juniper II")
        XCTAssertEqual(animals.count, 2)
        XCTAssertEqual(try target.mainContext.fetch(FetchDescriptor<Press>()).count, 2)
    }

    func testPreviewCountsWithoutChangingTheStore() throws {
        let bundle = try sourceBundle()
        let target = try TestSupport.container()
        let preview = try JSONImporter.preview(bundle, context: target.mainContext)
        XCTAssertEqual(preview.totalUpdated, 0)
        XCTAssertEqual(preview.totalInserted, recordCount(bundle))
        XCTAssertEqual(preview.entries.map(\.entity), EntityNames.all)
        XCTAssertTrue(preview.lines.contains("Animals: 2 new, 0 updated"))
        XCTAssertEqual(try target.mainContext.fetch(FetchDescriptor<Animal>()).count, 0)
        XCTAssertEqual(try target.mainContext.fetch(FetchDescriptor<Press>()).count, 0)
    }

    func testMergedRelationshipsAreWired() throws {
        let target = try TestSupport.container()
        try JSONImporter.merge(try sourceBundle(), context: target.mainContext)
        let press = try XCTUnwrap(try target.mainContext.fetch(FetchDescriptor<Press>()).first)
        XCTAssertEqual(press.button?.label, "Out")
        XCTAssertEqual(press.animal?.name, "Juniper")
        XCTAssertEqual(press.kind, .spontaneous)
        let observation = try XCTUnwrap(try target.mainContext.fetch(FetchDescriptor<PoopObservation>()).first)
        XCTAssertEqual(Set((observation.tags ?? []).map(\.name)), ["normal", "soft"])
        let item = try XCTUnwrap(try target.mainContext.fetch(FetchDescriptor<FeedItem>()).first)
        XCTAssertEqual(item.feeding?.day?.outdoorHours, 6.5)
        let turn = try XCTUnwrap(try target.mainContext.fetch(FetchDescriptor<CheckInTurn>()).first)
        XCTAssertEqual(turn.checkIn?.model, "claude-opus-5")
        let vocalization = try XCTUnwrap(try target.mainContext.fetch(FetchDescriptor<Vocalization>()).first)
        XCTAssertEqual(vocalization.recording?.audioFilename, "ccc-audio.m4a")
        XCTAssertEqual(vocalization.mfcc.count, 13)
    }

    func testRecordsWhoseMediaFilesAreMissingStillImport() throws {
        let target = try TestSupport.container()
        try JSONImporter.merge(try sourceBundle(), context: target.mainContext)
        let health = try XCTUnwrap(try target.mainContext.fetch(FetchDescriptor<HealthCheckIn>()).first)
        XCTAssertEqual(health.photoFilename, "bbb-photo.jpg")
        XCTAssertFalse(FileMediaStore().exists("bbb-photo.jpg"))
        let recording = try XCTUnwrap(try target.mainContext.fetch(FetchDescriptor<VoiceRecording>()).first)
        XCTAssertEqual(recording.audioFilename, "ccc-audio.m4a")
        XCTAssertFalse(FileMediaStore().exists("ccc-audio.m4a"))
    }
}
```

`AppTests/JSONRoundTripTests.swift`:
```swift
import SwiftData
import XCTest
@testable import AnimalTracker

@MainActor
final class JSONRoundTripTests: XCTestCase {
    func testExportImportExportProducesTheSameJSONDocument() throws {
        let source = try ExportTestFixtures.populatedContainer()
        let firstBundle = try ExportBundleBuilder.build(context: source.mainContext)
        let firstData = try JSONExporter.data(firstBundle)

        let fresh = try TestSupport.container()
        let decoded = try JSONImporter.decode(firstData)
        let counts = try JSONImporter.merge(decoded, context: fresh.mainContext)
        XCTAssertEqual(counts.totalUpdated, 0)
        XCTAssertGreaterThan(counts.totalInserted, 0)

        let secondBundle = try ExportBundleBuilder.build(context: fresh.mainContext)
        let secondData = try JSONExporter.data(secondBundle)

        XCTAssertEqual(try normalized(firstData), try normalized(secondData))
        XCTAssertEqual(firstBundle, secondBundle)
        XCTAssertEqual(CSVExporter.files(firstBundle).map { $0.contents },
                       CSVExporter.files(secondBundle).map { $0.contents })
    }

    /// Re-serializes with sorted keys so the comparison does not depend on key order.
    private func normalized(_ data: Data) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: data)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test-app.sh`
Expected: build errors, `JSONImporter.preview` and `JSONImporter.merge` not found.

- [ ] **Step 3: Implement**

Append to `App/IO/JSONImporter.swift`, inside the `enum JSONImporter` body:
```swift
    /// What a merge would do. Reads only; the store is untouched.
    static func preview(_ bundle: ExportBundle, context: ModelContext) throws -> ImportCounts {
        func entry<T: PersistentModel>(_ entity: String, _ type: T.Type, _ ids: [String],
                                       _ idOf: (T) -> UUID) throws -> ImportCounts.Entry {
            let existing = Set(try context.fetch(FetchDescriptor<T>()).map(idOf))
            var updated = 0
            for raw in ids {
                if let uuid = UUID(uuidString: raw), existing.contains(uuid) { updated += 1 }
            }
            return ImportCounts.Entry(entity: entity, inserted: ids.count - updated, updated: updated)
        }

        return ImportCounts(entries: [
            try entry(EntityNames.animals, Animal.self, bundle.animals.map(\.id), { $0.id }),
            try entry(EntityNames.buttons, AACButton.self, bundle.buttons.map(\.id), { $0.id }),
            try entry(EntityNames.presses, Press.self, bundle.presses.map(\.id), { $0.id }),
            try entry(EntityNames.feedDays, FeedDay.self, bundle.feedDays.map(\.id), { $0.id }),
            try entry(EntityNames.feedings, Feeding.self, bundle.feedings.map(\.id), { $0.id }),
            try entry(EntityNames.feedItems, FeedItem.self, bundle.feedItems.map(\.id), { $0.id }),
            try entry(EntityNames.poopTags, PoopTag.self, bundle.poopTags.map(\.id), { $0.id }),
            try entry(EntityNames.poopObservations, PoopObservation.self,
                      bundle.poopObservations.map(\.id), { $0.id }),
            try entry(EntityNames.healthCheckIns, HealthCheckIn.self,
                      bundle.healthCheckIns.map(\.id), { $0.id }),
            try entry(EntityNames.oralCheckIns, OralCheckIn.self, bundle.oralCheckIns.map(\.id), { $0.id }),
            try entry(EntityNames.checkInTurns, CheckInTurn.self, bundle.checkInTurns.map(\.id), { $0.id }),
            try entry(EntityNames.voiceTags, VoiceTag.self, bundle.voiceTags.map(\.id), { $0.id }),
            try entry(EntityNames.voiceRecordings, VoiceRecording.self,
                      bundle.voiceRecordings.map(\.id), { $0.id }),
            try entry(EntityNames.vocalizations, Vocalization.self, bundle.vocalizations.map(\.id), { $0.id }),
        ])
    }

    /// Updates a record when its id is already in the store, inserts it otherwise, and saves once.
    /// Records present in the store but absent from the file are left alone.
    @discardableResult
    static func merge(_ bundle: ExportBundle, context: ModelContext) throws -> ImportCounts {
        var animals = try index(Animal.self, in: context) { $0.id }
        var buttons = try index(AACButton.self, in: context) { $0.id }
        var presses = try index(Press.self, in: context) { $0.id }
        var feedDays = try index(FeedDay.self, in: context) { $0.id }
        var feedings = try index(Feeding.self, in: context) { $0.id }
        var feedItems = try index(FeedItem.self, in: context) { $0.id }
        var poopTags = try index(PoopTag.self, in: context) { $0.id }
        var poopObservations = try index(PoopObservation.self, in: context) { $0.id }
        var healthCheckIns = try index(HealthCheckIn.self, in: context) { $0.id }
        var oralCheckIns = try index(OralCheckIn.self, in: context) { $0.id }
        var checkInTurns = try index(CheckInTurn.self, in: context) { $0.id }
        var voiceTags = try index(VoiceTag.self, in: context) { $0.id }
        var voiceRecordings = try index(VoiceRecording.self, in: context) { $0.id }
        var vocalizations = try index(Vocalization.self, in: context) { $0.id }

        var byEntity: [String: ImportCounts.Entry] = [:]
        func record(_ entry: ImportCounts.Entry) { byEntity[entry.entity] = entry }

        // Parents first, so children can point at models that already exist in the table.
        record(upsert(EntityNames.animals, bundle.animals, id: { $0.id }, table: &animals, context: context,
                      make: { Animal(name: "", species: "") }, setID: { $0.id = $1 }) { model, row in
            model.createdAt = ExportFormatters.date(fromTimestamp: row.createdAt) ?? model.createdAt
            model.name = row.name
            model.species = row.species
            model.colorHex = row.colorHex
            model.photoFilename = row.photoFilename
            model.photoThumbnailFilename = row.photoThumbnailFilename
            model.tracksOutdoorTime = row.tracksOutdoorTime
            model.sortOrder = row.sortOrder
            model.isArchived = row.isArchived
            model.note = row.note
        })

        record(upsert(EntityNames.poopTags, bundle.poopTags, id: { $0.id }, table: &poopTags, context: context,
                      make: { PoopTag() }, setID: { $0.id = $1 }) { model, row in
            model.createdAt = ExportFormatters.date(fromTimestamp: row.createdAt) ?? model.createdAt
            model.name = row.name
            model.colorHex = row.colorHex
            model.isBuiltIn = row.isBuiltIn
            model.isHidden = row.isHidden
            model.sortOrder = row.sortOrder
        })

        record(upsert(EntityNames.voiceTags, bundle.voiceTags, id: { $0.id }, table: &voiceTags, context: context,
                      make: { VoiceTag() }, setID: { $0.id = $1 }) { model, row in
            model.createdAt = ExportFormatters.date(fromTimestamp: row.createdAt) ?? model.createdAt
            model.kindRaw = row.kind
            model.name = row.name
            model.isBuiltIn = row.isBuiltIn
            model.sortOrder = row.sortOrder
        })

        record(upsert(EntityNames.buttons, bundle.buttons, id: { $0.id }, table: &buttons, context: context,
                      make: { AACButton() }, setID: { $0.id = $1 }) { model, row in
            model.createdAt = ExportFormatters.date(fromTimestamp: row.createdAt) ?? model.createdAt
            model.animal = resolve(row.animalId, in: animals)
            model.label = row.label
            model.colorHex = row.colorHex
            model.sortOrder = row.sortOrder
            model.isArchived = row.isArchived
        })

        record(upsert(EntityNames.feedDays, bundle.feedDays, id: { $0.id }, table: &feedDays, context: context,
                      make: { FeedDay() }, setID: { $0.id = $1 }) { model, row in
            model.createdAt = ExportFormatters.date(fromTimestamp: row.createdAt) ?? model.createdAt
            model.animal = resolve(row.animalId, in: animals)
            model.date = ExportFormatters.date(fromDay: row.date) ?? model.date
            model.outdoorHours = row.outdoorHours
            model.outdoorAreaAcres = row.outdoorAreaAcres
            model.note = row.note
        })

        record(upsert(EntityNames.oralCheckIns, bundle.oralCheckIns, id: { $0.id },
                      table: &oralCheckIns, context: context,
                      make: { OralCheckIn() }, setID: { $0.id = $1 }) { model, row in
            model.createdAt = ExportFormatters.date(fromTimestamp: row.createdAt) ?? model.createdAt
            model.animal = resolve(row.animalId, in: animals)
            model.startedAt = ExportFormatters.date(fromTimestamp: row.startedAt) ?? model.startedAt
            model.endedAt = row.endedAt.flatMap { ExportFormatters.date(fromTimestamp: $0) }
            model.statusRaw = row.status
            model.model = row.model
            model.inputTokens = row.inputTokens
            model.outputTokens = row.outputTokens
            model.createdRecordIdsJSON = row.createdRecordIdsJSON
            model.errorMessage = row.errorMessage
        })

        record(upsert(EntityNames.voiceRecordings, bundle.voiceRecordings, id: { $0.id },
                      table: &voiceRecordings, context: context,
                      make: { VoiceRecording() }, setID: { $0.id = $1 }) { model, row in
            model.createdAt = ExportFormatters.date(fromTimestamp: row.createdAt) ?? model.createdAt
            model.animal = resolve(row.animalId, in: animals)
            model.recordedAt = ExportFormatters.date(fromTimestamp: row.recordedAt) ?? model.recordedAt
            model.durationS = row.durationS
            model.audioFilename = row.audioFilename
            model.statusRaw = row.status
            model.errorMessage = row.errorMessage
            model.note = row.note
            model.activityTag = row.activityTag
            model.meaningTag = row.meaningTag
            model.userConfidence = row.userConfidence
            model.editedAt = row.editedAt.flatMap { ExportFormatters.date(fromTimestamp: $0) }
        })

        record(upsert(EntityNames.presses, bundle.presses, id: { $0.id }, table: &presses, context: context,
                      make: { Press() }, setID: { $0.id = $1 }) { model, row in
            model.createdAt = ExportFormatters.date(fromTimestamp: row.createdAt) ?? model.createdAt
            model.animal = resolve(row.animalId, in: animals)
            model.button = resolve(row.buttonId, in: buttons)
            model.timestamp = ExportFormatters.date(fromTimestamp: row.timestamp) ?? model.timestamp
            model.kindRaw = row.kind
            model.note = row.note
            model.editedAt = row.editedAt.flatMap { ExportFormatters.date(fromTimestamp: $0) }
        })

        record(upsert(EntityNames.feedings, bundle.feedings, id: { $0.id }, table: &feedings, context: context,
                      make: { Feeding() }, setID: { $0.id = $1 }) { model, row in
            model.createdAt = ExportFormatters.date(fromTimestamp: row.createdAt) ?? model.createdAt
            model.day = resolve(row.dayId, in: feedDays)
            model.time = ExportFormatters.date(fromTimestamp: row.time) ?? model.time
            model.note = row.note
        })

        record(upsert(EntityNames.feedItems, bundle.feedItems, id: { $0.id }, table: &feedItems, context: context,
                      make: { FeedItem() }, setID: { $0.id = $1 }) { model, row in
            model.createdAt = ExportFormatters.date(fromTimestamp: row.createdAt) ?? model.createdAt
            model.feeding = resolve(row.feedingId, in: feedings)
            model.categoryRaw = row.category
            model.type = row.type
            model.amount = row.amount
            model.unit = row.unit
            model.sortOrder = row.sortOrder
        })

        record(upsert(EntityNames.poopObservations, bundle.poopObservations, id: { $0.id },
                      table: &poopObservations, context: context,
                      make: { PoopObservation() }, setID: { $0.id = $1 }) { model, row in
            model.createdAt = ExportFormatters.date(fromTimestamp: row.createdAt) ?? model.createdAt
            model.animal = resolve(row.animalId, in: animals)
            model.timestamp = ExportFormatters.date(fromTimestamp: row.timestamp) ?? model.timestamp
            model.tags = row.tagIds.compactMap { resolve($0, in: poopTags) }
            model.note = row.note
            model.editedAt = row.editedAt.flatMap { ExportFormatters.date(fromTimestamp: $0) }
        })

        record(upsert(EntityNames.healthCheckIns, bundle.healthCheckIns, id: { $0.id },
                      table: &healthCheckIns, context: context,
                      make: { HealthCheckIn() }, setID: { $0.id = $1 }) { model, row in
            model.createdAt = ExportFormatters.date(fromTimestamp: row.createdAt) ?? model.createdAt
            model.animal = resolve(row.animalId, in: animals)
            model.timestamp = ExportFormatters.date(fromTimestamp: row.timestamp) ?? model.timestamp
            model.photoFilename = row.photoFilename
            model.thumbnailFilename = row.thumbnailFilename
            model.videoFilename = row.videoFilename
            model.note = row.note
            model.editedAt = row.editedAt.flatMap { ExportFormatters.date(fromTimestamp: $0) }
        })

        record(upsert(EntityNames.checkInTurns, bundle.checkInTurns, id: { $0.id },
                      table: &checkInTurns, context: context,
                      make: { CheckInTurn() }, setID: { $0.id = $1 }) { model, row in
            model.createdAt = ExportFormatters.date(fromTimestamp: row.createdAt) ?? model.createdAt
            model.checkIn = resolve(row.checkInId, in: oralCheckIns)
            model.index = row.index
            model.roleRaw = row.role
            model.text = row.text
            model.timestamp = ExportFormatters.date(fromTimestamp: row.timestamp) ?? model.timestamp
            model.draftJSON = row.draftJSON
        })

        record(upsert(EntityNames.vocalizations, bundle.vocalizations, id: { $0.id },
                      table: &vocalizations, context: context,
                      make: { Vocalization() }, setID: { $0.id = $1 }) { model, row in
            model.createdAt = ExportFormatters.date(fromTimestamp: row.createdAt) ?? model.createdAt
            model.recording = resolve(row.recordingId, in: voiceRecordings)
            model.startS = row.startS
            model.endS = row.endS
            model.f0Mean = row.f0Mean
            model.f0Min = row.f0Min
            model.f0Max = row.f0Max
            model.f0Slope = row.f0Slope
            model.voicedFraction = row.voicedFraction
            model.rmsDb = row.rmsDb
            model.spectralCentroidHz = row.spectralCentroidHz
            model.mfcc = row.mfcc
            model.activityTag = row.activityTag
            model.meaningTag = row.meaningTag
            model.userConfidence = row.userConfidence
            model.overridden = row.overridden
        })

        try context.save()
        return ImportCounts(entries: EntityNames.all.compactMap { byEntity[$0] })
    }

    private static func index<T: PersistentModel>(_ type: T.Type, in context: ModelContext,
                                                  id: (T) -> UUID) throws -> [UUID: T] {
        Dictionary(try context.fetch(FetchDescriptor<T>()).map { (id($0), $0) },
                   uniquingKeysWith: { first, _ in first })
    }

    private static func resolve<T: PersistentModel>(_ rawID: String?, in table: [UUID: T]) -> T? {
        guard let rawID, let uuid = UUID(uuidString: rawID) else { return nil }
        return table[uuid]
    }

    /// Update the model already carrying this id, or insert a new one, then copy the row onto it.
    private static func upsert<T: PersistentModel, Row>(
        _ entity: String,
        _ rows: [Row],
        id: (Row) -> String,
        table: inout [UUID: T],
        context: ModelContext,
        make: () -> T,
        setID: (T, UUID) -> Void,
        apply: (T, Row) -> Void
    ) -> ImportCounts.Entry {
        var inserted = 0
        var updated = 0
        for row in rows {
            guard let uuid = UUID(uuidString: id(row)) else { continue }
            let model: T
            if let existing = table[uuid] {
                model = existing
                updated += 1
            } else {
                model = make()
                setID(model, uuid)
                context.insert(model)
                table[uuid] = model
                inserted += 1
            }
            apply(model, row)
        }
        return ImportCounts.Entry(entity: entity, inserted: inserted, updated: updated)
    }
```

- [ ] **Step 4: Run to verify pass**

Run: `scripts/test-app.sh`
Expected: 6 more tests than after Task 6, 0 failures. The round trip test is the one that proves the exporter and importer agree on every field.

- [ ] **Step 5: Commit**

```bash
git add App/IO/JSONImporter.swift AppTests/JSONImporterMergeTests.swift AppTests/JSONRoundTripTests.swift
git commit -m "feat(io): merge-by-id import with per-entity counts and a JSON round trip test

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: ExportWriter, share sheet, and the Settings Export and Import rows

**Files:**
- Create: `App/IO/ExportWriter.swift`, `App/Views/Settings/ShareSheet.swift`, `App/Views/Settings/ExportDataRow.swift`, `App/Views/Settings/ImportDataRow.swift`
- Modify: `App/Views/Settings/SettingsView.swift` (the two lines in the `Section("Data")` block)
- Test: `AppTests/ExportWriterTests.swift`

**Interfaces:**
- Consumes: `ExportBundleBuilder.build(context:)`, `CSVExporter.files(_:)`, `JSONExporter.data(_:)` and `JSONExporter.filename`, `JSONImporter.decode(_:)`, `JSONImporter.preview(_:context:)`, `JSONImporter.merge(_:context:)`, `ImportCounts`, `ExportFormatters.day(_:)`; Plan A's `SettingsView` and `SettingsPlaceholderRow`.
- Produces: `enum ExportWriter` with `static func makeTemporaryDirectory(now: Date = Date()) throws -> URL` and `static func writeAll(_ bundle: ExportBundle, to directory: URL) throws -> [URL]` returning the six CSVs then the JSON; `struct ShareSheet: UIViewControllerRepresentable` taking `items: [URL]`; `struct ExportDataRow: View`; `struct ImportDataRow: View`.

**Tests added: 3.** The three SwiftUI views are verified by running the app, as Plan A does for its views.

- [ ] **Step 1: Write the failing tests**

`AppTests/ExportWriterTests.swift`:
```swift
import SwiftData
import XCTest
@testable import AnimalTracker

@MainActor
final class ExportWriterTests: XCTestCase {
    private func populatedBundle() throws -> ExportBundle {
        try ExportBundleBuilder.build(context: ExportTestFixtures.populatedContainer().mainContext)
    }

    func testWritesSevenFilesWithExactNames() throws {
        let directory = try ExportWriter.makeTemporaryDirectory()
        let urls = try ExportWriter.writeAll(try populatedBundle(), to: directory)
        XCTAssertEqual(urls.map(\.lastPathComponent),
                       ["presses.csv", "feedings.csv", "poop.csv", "health.csv",
                        "voice-recordings.csv", "vocalizations.csv", "animal-tracker.json"])
        for url in urls {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.lastPathComponent)
            XCTAssertGreaterThan(try Data(contentsOf: url).count, 0, url.lastPathComponent)
        }
    }

    func testEachExportGetsItsOwnFolder() throws {
        let first = try ExportWriter.makeTemporaryDirectory()
        let second = try ExportWriter.makeTemporaryDirectory()
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.lastPathComponent.hasPrefix("AnimalTracker-export-"), first.lastPathComponent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
    }

    func testTheWrittenJSONDecodesBackToTheSameBundle() throws {
        let bundle = try populatedBundle()
        let urls = try ExportWriter.writeAll(bundle, to: try ExportWriter.makeTemporaryDirectory())
        let jsonURL = try XCTUnwrap(urls.last)
        XCTAssertEqual(try JSONImporter.decode(try Data(contentsOf: jsonURL)), bundle)
        let pressesURL = try XCTUnwrap(urls.first)
        let csv = try String(contentsOf: pressesURL, encoding: .utf8)
        XCTAssertEqual(csv.components(separatedBy: "\n")[0], "animal,timestamp_iso8601,button,kind,note")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test-app.sh`
Expected: build error, `ExportWriter` not found.

- [ ] **Step 3: Implement the writer and the share sheet**

`App/IO/ExportWriter.swift`:
```swift
import Foundation

/// Puts the seven export files in a fresh temporary folder so the share sheet always sees
/// a complete, current set and repeated exports never overwrite each other.
enum ExportWriter {
    static func makeTemporaryDirectory(now: Date = Date()) throws -> URL {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnimalTracker-export-\(ExportFormatters.day(now))-\(suffix)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// The six CSV files in spec order, then animal-tracker.json.
    static func writeAll(_ bundle: ExportBundle, to directory: URL) throws -> [URL] {
        var urls: [URL] = []
        for file in CSVExporter.files(bundle) {
            let url = directory.appendingPathComponent(file.name)
            try Data(file.contents.utf8).write(to: url, options: .atomic)
            urls.append(url)
        }
        let jsonURL = directory.appendingPathComponent(JSONExporter.filename)
        try JSONExporter.data(bundle).write(to: jsonURL, options: .atomic)
        urls.append(jsonURL)
        return urls
    }
}
```

`App/Views/Settings/ShareSheet.swift`:
```swift
import SwiftUI
import UIKit

/// UIActivityViewController wrapper. The activity items are file URLs, so Save to Files,
/// AirDrop and Mail all receive the real files.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
```

- [ ] **Step 4: Implement the two Settings rows**

`App/Views/Settings/ExportDataRow.swift`:
```swift
import SwiftData
import SwiftUI

/// Settings > Data > Export. Builds the bundle, writes all seven files, then shares them.
struct ExportDataRow: View {
    @Environment(\.modelContext) private var context
    @State private var urls: [URL] = []
    @State private var isWorking = false
    @State private var showShare = false
    @State private var errorMessage: String?

    var body: some View {
        Button {
            export()
        } label: {
            HStack {
                Label("Export", systemImage: "square.and.arrow.up")
                Spacer()
                if isWorking {
                    ProgressView()
                } else {
                    Text("7 files").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .disabled(isWorking)
        .sheet(isPresented: $showShare) { ShareSheet(items: urls) }
        .alert("Export failed",
               isPresented: Binding(get: { errorMessage != nil },
                                    set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func export() {
        isWorking = true
        do {
            let bundle = try ExportBundleBuilder.build(context: context)
            let directory = try ExportWriter.makeTemporaryDirectory()
            urls = try ExportWriter.writeAll(bundle, to: directory)
            isWorking = false
            showShare = true
        } catch {
            isWorking = false
            errorMessage = error.localizedDescription
        }
    }
}
```

`App/Views/Settings/ImportDataRow.swift`:
```swift
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Settings > Data > Import. Reads animal-tracker.json, shows what the merge would do,
/// waits for confirmation, merges, and reports.
struct ImportDataRow: View {
    @Environment(\.modelContext) private var context
    @State private var showPicker = false
    @State private var pending: ExportBundle?
    @State private var preview: ImportCounts?
    @State private var resultMessage: String?
    @State private var errorMessage: String?

    var body: some View {
        Button {
            showPicker = true
        } label: {
            Label("Import", systemImage: "square.and.arrow.down")
        }
        .fileImporter(isPresented: $showPicker,
                      allowedContentTypes: [.json],
                      allowsMultipleSelection: false) { result in
            load(result)
        }
        .alert("Import this file?",
               isPresented: Binding(get: { preview != nil },
                                    set: { if !$0 { preview = nil; pending = nil } })) {
            Button("Cancel", role: .cancel) { preview = nil; pending = nil }
            Button("Import") { apply() }
        } message: {
            Text(previewText)
        }
        .alert("Import finished",
               isPresented: Binding(get: { resultMessage != nil },
                                    set: { if !$0 { resultMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(resultMessage ?? "")
        }
        .alert("Import failed",
               isPresented: Binding(get: { errorMessage != nil },
                                    set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var previewText: String {
        guard let preview else { return "" }
        guard !preview.lines.isEmpty else { return "This file has no records." }
        return preview.lines.joined(separator: "\n")
    }

    private func load(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let bundle = try JSONImporter.decode(try Data(contentsOf: url))
            pending = bundle
            preview = try JSONImporter.preview(bundle, context: context)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func apply() {
        guard let bundle = pending else { return }
        do {
            let counts = try JSONImporter.merge(bundle, context: context)
            resultMessage = counts.lines.isEmpty
                ? "Nothing to import."
                : "Added \(counts.totalInserted) records and updated \(counts.totalUpdated)."
        } catch {
            errorMessage = error.localizedDescription
        }
        pending = nil
        preview = nil
    }
}
```

- [ ] **Step 5: Replace the two placeholder rows in SettingsView**

In `App/Views/Settings/SettingsView.swift`, the `Section("Data")` block currently reads:
```swift
            Section("Data") {
                SettingsPlaceholderRow(title: "Export")
                SettingsPlaceholderRow(title: "Import")
            }
```
Replace those two lines so the block reads:
```swift
            Section("Data") {
                ExportDataRow()
                ImportDataRow()
            }
```
Leave `SettingsPlaceholderRow` itself in place: the Tags section still uses it if Plans E and B have not replaced those rows.

- [ ] **Step 6: Run to verify pass**

Run: `scripts/test-app.sh`
Expected: 3 more tests than after Task 7, 0 failures. Across all eight tasks this plan adds 49 tests.

Then run: `scripts/run-sim.sh`. Read `build/screenshot.png` and confirm the build succeeds. In the simulator, add an animal, log one press, open Settings and tap Export: the share sheet must list seven items. Choose Save to Files, then tap Import, pick `animal-tracker.json`, confirm the counts alert names the entities, and confirm the finish alert reports zero new and the same number updated on a re-import into the same store.

- [ ] **Step 7: Commit**

```bash
git add App/IO/ExportWriter.swift App/Views/Settings/ShareSheet.swift App/Views/Settings/ExportDataRow.swift App/Views/Settings/ImportDataRow.swift App/Views/Settings/SettingsView.swift AppTests/ExportWriterTests.swift
git commit -m "feat(settings): export seven files through the share sheet and import JSON after a counted confirmation

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```
