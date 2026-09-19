# AnimalTracker Plan C: Buttons Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Buttons subsystem: the `AACButton` and `Press` models, the pure `Sequencer` and `StatsAggregator` logic, and the Buttons tab with its Log, History, Stats, and Manage sections.

**Architecture:** Two SwiftData models registered in the shared container, plus a `PressSnapshot` value type so all counting logic is pure and unit-tested without a store. `Sequencer` turns a flat list of snapshots into runs of presses; `StatsAggregator` counts those snapshots and runs five ways. The tab is one root view (`ButtonsTabView`) with a segmented control over four child views; the root reads the animal from `@Environment(\.selectedAnimal)` and never creates its own `NavigationStack`, because Plan A's `RootTabView` already wraps each tab in one with the shared animal toolbar.

**Tech Stack:** Swift 5 language mode, SwiftUI, SwiftData, Swift Charts, XCTest.

**Spec:** `docs/superpowers/specs/2026-09-16-animal-tracker-design.md` (sections: Constraints, Top-level navigation, Data model/Buttons domain, Settings, Buttons tab, Logic, Error handling, Testing) and `docs/superpowers/specs/2026-09-18-model-contract.md` (binding model and snapshot names). Builds on `docs/superpowers/plans/2026-09-18-animal-tracker-A-foundation.md`, which is assumed fully implemented.

## Global Constraints

- iOS deployment target `17.0`; Swift 5 language mode (`SWIFT_VERSION = 5.0`); never Swift 6 strict concurrency.
- SwiftUI, SwiftData, and Swift Charts only. No third-party packages, no iCloud, no new local packages, no change to `project.yml` (Swift Charts is a system framework and needs no target configuration).
- Test target `AnimalTrackerTests`, files in `AppTests/`, `@testable import AnimalTracker`, run with `scripts/test-app.sh`.
- Tests that need the store use `TestSupport.container()` (in-memory). Tests of pure logic must not import SwiftData and must not create a container.
- Visual checks use `scripts/run-sim.sh`, which writes `build/screenshot.png`; read that file.
- Every model has `var id: UUID = UUID()` and `var createdAt: Date = Date()`; every stored property has a default or is optional; relationships are optional; enums are stored as `<name>Raw: String` with a computed accessor.
- Registration points this plan touches: `PersistenceController.modelTypes` gains `AACButton.self` and `Press.self`; `AnimalDeletionPolicy.recordCounts` gains a `"presses"` entry and a `"buttons"` entry; `App/Logic/Snapshots.swift` gains `PressSnapshot`; `App/RootTabView.swift` swaps the Buttons tab placeholder for `ButtonsTabView()`. Nothing else in Plan A's files changes.
- Tab root views never declare a `NavigationStack` and never set a navigation title; `RootTabView` supplies both. They read `@Environment(\.selectedAnimal)` and show an empty state when it is nil.
- Settings keys used verbatim: `@AppStorage("sequenceWindowSeconds")` default `10`, `@AppStorage("defaultPressKind")` default `"spontaneous"`.
- Colors come from `ColorPalette` (Plan A): `ColorPalette.presets` is the 12-color palette, `ColorPalette.color(_:)` converts a hex string to a `Color`, `ColorPalette.hex(_:)` converts back, `ColorPalette.contrastingText(on:)` picks black or white.
- Chart rules, binding: one y-axis per chart and never a dual axis; every button keeps its own `colorHex` in every chart, so color follows the entity; a legend is present whenever a chart shows two or more series; the per-button chart is a horizontal bar stacked prompted vs spontaneous; the per-day chart is a stacked bar by button; the heatmap is hour (0 to 23) by button drawn with `RectangleMark` and opacity by count.
- SwiftData save failures surface as an alert and the change is not presented as saved.
- Commit after every task with the message shown; do not push. Every commit message ends with the trailer line `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.

## Assumptions

Decisions the spec left open, and how this plan resolves them.

1. **The sequence type is named `PressSequence`.** The spec writes `Sequencer.group(presses, window) -> [Sequence]`, but `Sequence` is a Swift standard library protocol and cannot be shadowed safely. The function signature is `Sequencer.group(_ presses: [PressSnapshot], window: TimeInterval) -> [PressSequence]`.
2. **`PressSnapshot.init?(_ press: Press)` is failable.** A `Press` whose `button` relationship is nil cannot produce a snapshot, since the snapshot carries `buttonID`, `buttonLabel`, and `buttonColorHex`. Views drop those presses; they can only exist transiently.
3. **Views query without SwiftData predicates and filter by animal in Swift.** `#Predicate` traversal of an optional to-one relationship is unreliable on iOS 17, and one keeper's records are a few thousand rows at most. The same applies to `AnimalDeletionPolicy.recordCounts`, which fetches and filters.
4. **The two Buttons settings live in the Manage section, not in Settings.** Plan A's `SettingsView` has no Buttons placeholder row, and the model contract lists no Settings change for this plan, so the sequence window stepper and the default press kind picker sit in a "Logging" section at the bottom of Manage. They write the same `@AppStorage` keys, so a later plan can move them without a data change.
5. **`repeatCounts` counts runs, not presses.** A sequence of four presses of "Out" counts as one repeat for "Out", because the spec pairs it with the sequence table, which also counts runs.
6. **Deterministic ordering.** `countsPerButton` sorts by total descending then label ascending; `countsPerDay` by day ascending then label ascending; `hourHeatmap` by label ascending then hour ascending; `sequenceCounts` and `repeatCounts` by count descending then key ascending. The spec only fixes "sorted by count" for the sequence table; the rest is chosen so tests and charts are stable.
7. **"7 days" means today plus the previous six local days**, and "30 days" today plus the previous 29, both starting at local midnight. "All" applies no lower bound.
8. **Prompted vs spontaneous is encoded as opacity on the button's own color.** The spec asks chart 1 to stack by kind and color by button at the same time. Color follows the entity, so the bar is the button's `colorHex`; the prompted segment is drawn at 0.5 opacity and the spontaneous segment at full opacity, with a legend that says so.
9. **The heatmap emits cells only for hours that have presses**, and fixes the x scale to `0...24` so empty hours read as gaps rather than shifting the grid.
10. **Button labels are unique per animal** among that animal's buttons, case-insensitively. The form blocks duplicates. This keeps one color per label in the per-day chart's style scale.
11. **A long press that logs a new press opens the note sheet and shows no toast.** The sheet is the feedback; a toast under it would be noise. A plain tap always shows the toast.
12. **A tile uses `LongPressGesture(...).exclusively(before: TapGesture())`,** so exactly one of the two actions fires. A `Button` with a separate long-press gesture can fire both.

## File Structure

```
App/Models/AACButton.swift                    AACButton model, pressCount, canDelete
App/Models/Press.swift                        Press model, kind accessor
App/Logic/Snapshots.swift                     MODIFIED: add PressSnapshot
App/Logic/Sequencer.swift                     PressSequence and Sequencer.group
App/Logic/StatsAggregator.swift               five counting functions over snapshots
App/Logic/LogRules.swift                      60-second note rule and toast text
App/Logic/HistoryGrouping.swift               PressDaySection and day grouping for History
App/Logic/StatsRange.swift                    7 days / 30 days / All and range filtering
App/Persistence/PersistenceController.swift   MODIFIED: register AACButton and Press
App/Persistence/AnimalDeletionPolicy.swift    MODIFIED: count presses and buttons
App/RootTabView.swift                         MODIFIED: Buttons tab shows ButtonsTabView
App/Views/Buttons/ButtonsTabView.swift        ButtonsSection segmented control, no NavigationStack
App/Views/Buttons/ManageButtonsView.swift     list, reorder, archive, delete, logging settings
App/Views/Buttons/ButtonFormView.swift        add and edit: label and color
App/Views/Buttons/ButtonLogView.swift         tile grid, kind toggle, toast with undo
App/Views/Buttons/PressNoteSheet.swift        note sheet reached by long press
App/Views/Buttons/ButtonHistoryView.swift     day sections, sequence rows, swipe delete
App/Views/Buttons/PressEditView.swift         edit timestamp, kind, note
App/Views/Buttons/ButtonStatsView.swift       range picker, three charts, two tables
App/Views/Buttons/ButtonChartLegends.swift    ButtonColorLegend, PressKindLegend, HeatmapIntensityLegend
AppTests/ButtonModelTests.swift               models, deny rule via canDelete, deletion policy
AppTests/PressSnapshotTests.swift             snapshot copies button identity
AppTests/SequencerTests.swift                 grouping by window
AppTests/StatsAggregatorTests.swift           five aggregations
AppTests/ButtonsSectionTests.swift            which section the tab opens on
AppTests/LogRulesTests.swift                  60-second rule and toast text
AppTests/HistoryGroupingTests.swift           day sections, newest first
AppTests/StatsRangeTests.swift                range start dates and filtering
```

Plan A ends at 19 passing tests. Each task below states the cumulative count.

---

### Task 1: AACButton and Press models, registration, PressSnapshot

**Files:**
- Create: `App/Models/AACButton.swift`, `App/Models/Press.swift`
- Modify: `App/Logic/Snapshots.swift` (append `PressSnapshot`), `App/Persistence/PersistenceController.swift` (`modelTypes`), `App/Persistence/AnimalDeletionPolicy.swift` (`recordCounts`)
- Test: `AppTests/ButtonModelTests.swift`, `AppTests/PressSnapshotTests.swift`

**Interfaces:**
- Consumes: `Animal`, `ColorPalette.defaultHex`, `PressKind`, `PersistenceController.modelTypes`, `AnimalDeletionPolicy.recordCounts(for:context:)`, `TestSupport.container()`, all from Plan A.
- Produces: `AACButton(label:colorHex:sortOrder:)` with `id, createdAt, label, colorHex, sortOrder, isArchived, animal, presses`, plus `var pressCount: Int` and `var canDelete: Bool`; `Press(timestamp:kind:note:)` with `id, createdAt, timestamp, kindRaw, kind, note, editedAt, button, animal`; `PressSnapshot(id:timestamp:buttonID:buttonLabel:buttonColorHex:kind:note:)` and `PressSnapshot?(_ press: Press)`; `AnimalDeletionPolicy.recordCounts` returning the keys `"presses"` and `"buttons"`.

- [ ] **Step 1: Write the failing tests**

`AppTests/ButtonModelTests.swift`:
```swift
import SwiftData
import XCTest
@testable import AnimalTracker

@MainActor
final class ButtonModelTests: XCTestCase {
    private func fixture() throws -> (context: ModelContext, animal: Animal, button: AACButton) {
        let context = try TestSupport.container().mainContext
        let animal = Animal(name: "Juniper", species: "horse")
        context.insert(animal)
        let button = AACButton(label: "Out", colorHex: "#2A78D6", sortOrder: 0)
        context.insert(button)
        button.animal = animal
        try context.save()
        return (context, animal, button)
    }

    func testButtonDefaultsAndRoundTrip() throws {
        let f = try fixture()
        let fetched = try f.context.fetch(FetchDescriptor<AACButton>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].label, "Out")
        XCTAssertEqual(fetched[0].colorHex, "#2A78D6")
        XCTAssertEqual(fetched[0].sortOrder, 0)
        XCTAssertFalse(fetched[0].isArchived)
        XCTAssertEqual(fetched[0].animal?.id, f.animal.id)
        XCTAssertEqual(fetched[0].pressCount, 0)
        XCTAssertTrue(fetched[0].canDelete)
    }

    func testDefaultButtonColorIsThePaletteDefault() {
        XCTAssertEqual(AACButton(label: "Treat").colorHex, ColorPalette.defaultHex)
        XCTAssertEqual(AACButton(label: "Treat").sortOrder, 0)
    }

    func testPressStoresKindAsRawString() throws {
        let f = try fixture()
        let press = Press(timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        f.context.insert(press)
        press.button = f.button
        press.animal = f.animal
        press.kind = .prompted
        try f.context.save()
        let fetched = try f.context.fetch(FetchDescriptor<Press>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].kindRaw, "prompted")
        XCTAssertEqual(fetched[0].kind, .prompted)
        XCTAssertNil(fetched[0].note)
        XCTAssertNil(fetched[0].editedAt)
        XCTAssertEqual(fetched[0].button?.label, "Out")
        XCTAssertEqual(fetched[0].timestamp, Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testPressDefaultsToSpontaneous() throws {
        let f = try fixture()
        let press = Press()
        f.context.insert(press)
        try f.context.save()
        XCTAssertEqual(press.kindRaw, "spontaneous")
        XCTAssertEqual(press.kind, .spontaneous)
    }

    func testButtonCannotBeDeletedWhileItHasPresses() throws {
        let f = try fixture()
        let press = Press()
        f.context.insert(press)
        press.button = f.button
        press.animal = f.animal
        try f.context.save()
        XCTAssertEqual(f.button.pressCount, 1)
        XCTAssertFalse(f.button.canDelete)
        f.context.delete(press)
        try f.context.save()
        XCTAssertEqual(f.button.pressCount, 0)
        XCTAssertTrue(f.button.canDelete)
    }

    func testDeletionPolicyCountsButtonsAndPressesPerAnimal() throws {
        let f = try fixture()
        let press = Press()
        f.context.insert(press)
        press.button = f.button
        press.animal = f.animal
        try f.context.save()

        let counts = try AnimalDeletionPolicy.recordCounts(for: f.animal, context: f.context)
        XCTAssertEqual(counts["buttons"], 1)
        XCTAssertEqual(counts["presses"], 1)
        XCTAssertFalse(try AnimalDeletionPolicy.canDelete(f.animal, context: f.context))

        let other = Animal(name: "Rex", species: "dog")
        f.context.insert(other)
        try f.context.save()
        let otherCounts = try AnimalDeletionPolicy.recordCounts(for: other, context: f.context)
        XCTAssertEqual(otherCounts["buttons"], 0)
        XCTAssertEqual(otherCounts["presses"], 0)
        XCTAssertTrue(try AnimalDeletionPolicy.canDelete(other, context: f.context))
    }
}
```

`AppTests/PressSnapshotTests.swift`:
```swift
import SwiftData
import XCTest
@testable import AnimalTracker

@MainActor
final class PressSnapshotTests: XCTestCase {
    func testSnapshotCopiesButtonIdentity() throws {
        let context = try TestSupport.container().mainContext
        let animal = Animal(name: "Juniper", species: "horse")
        context.insert(animal)
        let button = AACButton(label: "Treat", colorHex: "#EB6834", sortOrder: 2)
        context.insert(button)
        button.animal = animal
        let press = Press(timestamp: Date(timeIntervalSince1970: 1_700_000_000), kind: .prompted, note: "after grooming")
        context.insert(press)
        press.button = button
        press.animal = animal
        try context.save()

        let snapshot = try XCTUnwrap(PressSnapshot(press))
        XCTAssertEqual(snapshot.id, press.id)
        XCTAssertEqual(snapshot.timestamp, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(snapshot.buttonID, button.id)
        XCTAssertEqual(snapshot.buttonLabel, "Treat")
        XCTAssertEqual(snapshot.buttonColorHex, "#EB6834")
        XCTAssertEqual(snapshot.kind, .prompted)
        XCTAssertEqual(snapshot.note, "after grooming")
    }

    func testSnapshotIsNilWithoutAButton() throws {
        let context = try TestSupport.container().mainContext
        let press = Press()
        context.insert(press)
        try context.save()
        XCTAssertNil(PressSnapshot(press))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test-app.sh`
Expected: build errors, `AACButton`, `Press`, and `PressSnapshot` not found.

- [ ] **Step 3: Implement the models**

`App/Models/AACButton.swift`:
```swift
import Foundation
import SwiftData

/// One physical recordable sound button belonging to an animal.
@Model
final class AACButton {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    /// The word printed on the physical button, e.g. "Out".
    var label: String = ""
    /// Matches the marker on the physical button. One of ColorPalette.presets, or a custom hex.
    var colorHex: String = ColorPalette.defaultHex
    var sortOrder: Int = 0
    var isArchived: Bool = false
    var animal: Animal?
    /// Deny, not cascade: a button with history is archived, never deleted (spec, Buttons domain).
    @Relationship(deleteRule: .deny, inverse: \Press.button) var presses: [Press]?

    init(label: String, colorHex: String = ColorPalette.defaultHex, sortOrder: Int = 0) {
        self.label = label
        self.colorHex = colorHex
        self.sortOrder = sortOrder
    }

    var pressCount: Int { presses?.count ?? 0 }

    /// The UI offers Delete only for a button that has never been pressed.
    var canDelete: Bool { pressCount == 0 }
}
```

`App/Models/Press.swift`:
```swift
import Foundation
import SwiftData

/// One press of one button. Logged by tapping a tile in the Log grid.
@Model
final class Press {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    /// Editable after the fact from the History list.
    var timestamp: Date = Date()
    var kindRaw: String = PressKind.spontaneous.rawValue
    var note: String?
    var editedAt: Date?
    var button: AACButton?
    var animal: Animal?

    init(timestamp: Date = Date(), kind: PressKind = .spontaneous, note: String? = nil) {
        self.timestamp = timestamp
        self.kindRaw = kind.rawValue
        self.note = note
    }

    var kind: PressKind {
        get { PressKind(rawValue: kindRaw) ?? .spontaneous }
        set { kindRaw = newValue.rawValue }
    }
}
```

- [ ] **Step 4: Register the models and the record counts**

In `App/Persistence/PersistenceController.swift`, replace the `modelTypes` array with:
```swift
    /// Every @Model type in the app. Later plans append their models here.
    static let modelTypes: [any PersistentModel.Type] = [
        Animal.self,
        AACButton.self,
        Press.self,
    ]
```

In `App/Persistence/AnimalDeletionPolicy.swift`, replace `recordCounts(for:context:)` with:
```swift
    /// Record counts by domain name. Each domain plan adds one entry here.
    /// Fetch-and-filter rather than a #Predicate: optional to-one relationship traversal
    /// in predicates is unreliable on iOS 17, and these tables are small.
    static func recordCounts(for animal: Animal, context: ModelContext) throws -> [String: Int] {
        let animalID = animal.id
        var counts: [String: Int] = [:]
        counts["presses"] = try context.fetch(FetchDescriptor<Press>())
            .filter { $0.animal?.id == animalID }.count
        counts["buttons"] = try context.fetch(FetchDescriptor<AACButton>())
            .filter { $0.animal?.id == animalID }.count
        return counts
    }
```

- [ ] **Step 5: Add the snapshot**

Append to `App/Logic/Snapshots.swift`, below `AnimalSnapshot`:
```swift
/// A press with its button's identity copied in, so counting logic never touches the store.
struct PressSnapshot: Equatable, Identifiable {
    let id: UUID
    let timestamp: Date
    let buttonID: UUID
    let buttonLabel: String
    let buttonColorHex: String
    let kind: PressKind
    let note: String?

    init(id: UUID, timestamp: Date, buttonID: UUID, buttonLabel: String,
         buttonColorHex: String, kind: PressKind, note: String?) {
        self.id = id
        self.timestamp = timestamp
        self.buttonID = buttonID
        self.buttonLabel = buttonLabel
        self.buttonColorHex = buttonColorHex
        self.kind = kind
        self.note = note
    }

    /// Nil when the press has no button, which can only happen mid-edit.
    init?(_ press: Press) {
        guard let button = press.button else { return nil }
        self.init(id: press.id, timestamp: press.timestamp, buttonID: button.id,
                  buttonLabel: button.label, buttonColorHex: button.colorHex,
                  kind: press.kind, note: press.note)
    }
}
```

`App/Logic/Snapshots.swift` has no `import SwiftData` and must keep none: `Press` and `AACButton` are visible inside the module without it.

- [ ] **Step 6: Run to verify pass**

Run: `scripts/test-app.sh`
Expected: `Executed 27 tests, with 0 failures` (19 from Plan A plus 8 here).

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat(buttons): AACButton and Press models, container registration, PressSnapshot

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: Sequencer

**Files:**
- Create: `App/Logic/Sequencer.swift`
- Test: `AppTests/SequencerTests.swift`

**Interfaces:**
- Consumes: `PressSnapshot` from Task 1.
- Produces: `struct PressSequence: Equatable, Identifiable` with `init(presses: [PressSnapshot])`, `id: UUID`, `presses: [PressSnapshot]`, `start: Date`, `end: Date`, `labels: [String]`, `buttonIDs: [UUID]`, `isSingle: Bool`; `Sequencer.group(_ presses: [PressSnapshot], window: TimeInterval) -> [PressSequence]`.

- [ ] **Step 1: Write the failing test**

`AppTests/SequencerTests.swift`:
```swift
import XCTest
@testable import AnimalTracker

final class SequencerTests: XCTestCase {
    private let out = UUID()
    private let treat = UUID()
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func press(_ buttonID: UUID, _ label: String, _ offset: TimeInterval) -> PressSnapshot {
        PressSnapshot(id: UUID(), timestamp: base.addingTimeInterval(offset), buttonID: buttonID,
                      buttonLabel: label, buttonColorHex: "#2A78D6", kind: .spontaneous, note: nil)
    }

    func testEmptyInputMakesNoSequences() {
        XCTAssertTrue(Sequencer.group([], window: 10).isEmpty)
    }

    func testOnePressMakesOneSingleSequence() {
        let sequences = Sequencer.group([press(out, "Out", 0)], window: 10)
        XCTAssertEqual(sequences.count, 1)
        XCTAssertTrue(sequences[0].isSingle)
        XCTAssertEqual(sequences[0].labels, ["Out"])
        XCTAssertEqual(sequences[0].start, base)
        XCTAssertEqual(sequences[0].end, base)
    }

    func testGapEqualToTheWindowJoinsAndLargerSplits() {
        let joined = Sequencer.group([press(out, "Out", 0), press(treat, "Treat", 10)], window: 10)
        XCTAssertEqual(joined.count, 1)
        XCTAssertEqual(joined[0].labels, ["Out", "Treat"])

        let split = Sequencer.group([press(out, "Out", 0), press(treat, "Treat", 10.5)], window: 10)
        XCTAssertEqual(split.count, 2)
        XCTAssertEqual(split.map(\.labels), [["Out"], ["Treat"]])
    }

    func testGapIsMeasuredFromThePreviousPressNotTheSequenceStart() {
        let sequences = Sequencer.group(
            [press(out, "Out", 0), press(treat, "Treat", 9), press(out, "Out", 18)], window: 10)
        XCTAssertEqual(sequences.count, 1)
        XCTAssertEqual(sequences[0].labels, ["Out", "Treat", "Out"])
        XCTAssertEqual(sequences[0].buttonIDs, [out, treat, out])
        XCTAssertEqual(sequences[0].start, base)
        XCTAssertEqual(sequences[0].end, base.addingTimeInterval(18))
        XCTAssertFalse(sequences[0].isSingle)
    }

    func testUnsortedInputIsSortedAscendingFirst() {
        let sequences = Sequencer.group(
            [press(treat, "Treat", 5), press(out, "Out", 0), press(out, "Out", 60)], window: 10)
        XCTAssertEqual(sequences.map(\.labels), [["Out", "Treat"], ["Out"]])
    }

    func testZeroWindowSplitsEveryPress() {
        let sequences = Sequencer.group(
            [press(out, "Out", 0), press(out, "Out", 1), press(out, "Out", 2)], window: 0)
        XCTAssertEqual(sequences.count, 3)
        XCTAssertTrue(sequences.allSatisfy(\.isSingle))
    }

    func testSequenceIdIsTheFirstPressId() {
        let first = press(out, "Out", 0)
        let sequences = Sequencer.group([first, press(treat, "Treat", 2)], window: 10)
        XCTAssertEqual(sequences[0].id, first.id)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test-app.sh`
Expected: build errors, `Sequencer` and `PressSequence` not found.

- [ ] **Step 3: Implement**

`App/Logic/Sequencer.swift`:
```swift
import Foundation

/// One run of presses, each within the sequence window of the one before it.
struct PressSequence: Equatable, Identifiable {
    let id: UUID
    let presses: [PressSnapshot]

    init(presses: [PressSnapshot]) {
        self.id = presses.first?.id ?? UUID()
        self.presses = presses
    }

    var start: Date { presses.first?.timestamp ?? .distantPast }
    var end: Date { presses.last?.timestamp ?? .distantPast }
    var labels: [String] { presses.map(\.buttonLabel) }
    var buttonIDs: [UUID] { presses.map(\.buttonID) }
    var isSingle: Bool { presses.count == 1 }
}

enum Sequencer {
    /// Consecutive presses whose gap from the previous press is at most `window` seconds
    /// belong to the same sequence. Input may arrive in any order; it is sorted ascending first.
    static func group(_ presses: [PressSnapshot], window: TimeInterval) -> [PressSequence] {
        let sorted = presses.sorted { a, b in
            if a.timestamp != b.timestamp { return a.timestamp < b.timestamp }
            return a.id.uuidString < b.id.uuidString
        }
        guard let first = sorted.first else { return [] }

        var sequences: [PressSequence] = []
        var current: [PressSnapshot] = [first]
        for press in sorted.dropFirst() {
            let previous = current[current.count - 1].timestamp
            if press.timestamp.timeIntervalSince(previous) <= window {
                current.append(press)
            } else {
                sequences.append(PressSequence(presses: current))
                current = [press]
            }
        }
        sequences.append(PressSequence(presses: current))
        return sequences
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `scripts/test-app.sh`
Expected: `Executed 34 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(buttons): Sequencer groups presses into sequences by gap window

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: StatsAggregator

**Files:**
- Create: `App/Logic/StatsAggregator.swift`
- Test: `AppTests/StatsAggregatorTests.swift`

**Interfaces:**
- Consumes: `PressSnapshot` (Task 1), `PressSequence` and `Sequencer.group` (Task 2).
- Produces: `StatsAggregator.ButtonCount(buttonID:label:colorHex:prompted:spontaneous:)` with `total`; `StatsAggregator.DayCount(day:buttonID:label:colorHex:count:)`; `StatsAggregator.HourCell(hour:buttonID:label:colorHex:count:)`; `StatsAggregator.SequenceCount(labels:count:)`; `StatsAggregator.RepeatCount(buttonID:label:colorHex:count:)`; functions `countsPerButton(_:) -> [ButtonCount]`, `countsPerDay(_:calendar:) -> [DayCount]`, `hourHeatmap(_:calendar:) -> [HourCell]`, `sequenceCounts(_:) -> [SequenceCount]`, `repeatCounts(_:) -> [RepeatCount]`.

- [ ] **Step 1: Write the failing test**

`AppTests/StatsAggregatorTests.swift`:
```swift
import XCTest
@testable import AnimalTracker

final class StatsAggregatorTests: XCTestCase {
    private let out = UUID()
    private let treat = UUID()
    /// 2023-11-14 22:13:20 UTC. The tests pin a UTC calendar so day and hour bucketing is stable.
    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }

    private func press(_ buttonID: UUID, _ label: String, _ hex: String,
                       _ offset: TimeInterval, _ kind: PressKind = .spontaneous) -> PressSnapshot {
        PressSnapshot(id: UUID(), timestamp: base.addingTimeInterval(offset), buttonID: buttonID,
                      buttonLabel: label, buttonColorHex: hex, kind: kind, note: nil)
    }

    func testEmptyInputsReturnEmptyResults() {
        XCTAssertTrue(StatsAggregator.countsPerButton([]).isEmpty)
        XCTAssertTrue(StatsAggregator.countsPerDay([], calendar: utc).isEmpty)
        XCTAssertTrue(StatsAggregator.hourHeatmap([], calendar: utc).isEmpty)
        XCTAssertTrue(StatsAggregator.sequenceCounts([]).isEmpty)
        XCTAssertTrue(StatsAggregator.repeatCounts([]).isEmpty)
    }

    func testCountsPerButtonSplitsKindsAndSortsByTotalThenLabel() {
        let presses = [
            press(out, "Out", "#2A78D6", 0, .spontaneous),
            press(out, "Out", "#2A78D6", 100, .prompted),
            press(out, "Out", "#2A78D6", 200, .spontaneous),
            press(treat, "Treat", "#EB6834", 300, .prompted),
        ]
        let rows = StatsAggregator.countsPerButton(presses)
        XCTAssertEqual(rows.map(\.label), ["Out", "Treat"])
        XCTAssertEqual(rows[0].spontaneous, 2)
        XCTAssertEqual(rows[0].prompted, 1)
        XCTAssertEqual(rows[0].total, 3)
        XCTAssertEqual(rows[0].colorHex, "#2A78D6")
        XCTAssertEqual(rows[0].buttonID, out)
        XCTAssertEqual(rows[1].prompted, 1)
        XCTAssertEqual(rows[1].spontaneous, 0)
        XCTAssertEqual(rows[1].total, 1)
    }

    func testCountsPerDayGroupsByStartOfDayAndSortsOldestFirst() {
        let presses = [
            press(out, "Out", "#2A78D6", 0),
            press(out, "Out", "#2A78D6", 60),
            press(treat, "Treat", "#EB6834", 60 * 60 * 24),
        ]
        let rows = StatsAggregator.countsPerDay(presses, calendar: utc)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].label, "Out")
        XCTAssertEqual(rows[0].count, 2)
        XCTAssertEqual(rows[0].day, utc.startOfDay(for: base))
        XCTAssertEqual(rows[1].label, "Treat")
        XCTAssertEqual(rows[1].count, 1)
        XCTAssertEqual(rows[1].day, utc.startOfDay(for: base.addingTimeInterval(60 * 60 * 24)))
    }

    func testHourHeatmapCountsByHourAndButton() {
        let presses = [
            press(out, "Out", "#2A78D6", 0),
            press(out, "Out", "#2A78D6", 30),
            press(treat, "Treat", "#EB6834", 60 * 60),
        ]
        let cells = StatsAggregator.hourHeatmap(presses, calendar: utc)
        XCTAssertEqual(cells.count, 2)
        XCTAssertEqual(cells[0].label, "Out")
        XCTAssertEqual(cells[0].hour, 22)
        XCTAssertEqual(cells[0].count, 2)
        XCTAssertEqual(cells[0].colorHex, "#2A78D6")
        XCTAssertEqual(cells[1].label, "Treat")
        XCTAssertEqual(cells[1].hour, 23)
        XCTAssertEqual(cells[1].count, 1)
    }

    func testSequenceCountsNeedTwoDistinctButtonsAndSortByCount() {
        let sequences = Sequencer.group([
            press(out, "Out", "#2A78D6", 0), press(treat, "Treat", "#EB6834", 5),
            press(out, "Out", "#2A78D6", 100), press(treat, "Treat", "#EB6834", 105),
            press(treat, "Treat", "#EB6834", 200), press(out, "Out", "#2A78D6", 205),
            press(out, "Out", "#2A78D6", 300), press(out, "Out", "#2A78D6", 305),
        ], window: 10)
        let rows = StatsAggregator.sequenceCounts(sequences)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].labels, ["Out", "Treat"])
        XCTAssertEqual(rows[0].count, 2)
        XCTAssertEqual(rows[1].labels, ["Treat", "Out"])
        XCTAssertEqual(rows[1].count, 1)
    }

    func testRepeatCountsCountRunsOfOneButton() {
        let sequences = Sequencer.group([
            press(out, "Out", "#2A78D6", 0), press(out, "Out", "#2A78D6", 5),
            press(out, "Out", "#2A78D6", 100), press(out, "Out", "#2A78D6", 105),
            press(treat, "Treat", "#EB6834", 200), press(treat, "Treat", "#EB6834", 205),
            press(out, "Out", "#2A78D6", 300),
            press(out, "Out", "#2A78D6", 400), press(treat, "Treat", "#EB6834", 405),
        ], window: 10)
        let rows = StatsAggregator.repeatCounts(sequences)
        XCTAssertEqual(rows.map(\.label), ["Out", "Treat"])
        XCTAssertEqual(rows[0].count, 2)
        XCTAssertEqual(rows[0].buttonID, out)
        XCTAssertEqual(rows[1].count, 1)
        XCTAssertEqual(rows[1].colorHex, "#EB6834")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test-app.sh`
Expected: build errors, `StatsAggregator` not found.

- [ ] **Step 3: Implement**

`App/Logic/StatsAggregator.swift`:
```swift
import Foundation

/// Counting over press snapshots. Pure: no SwiftData, no SwiftUI, no current date.
enum StatsAggregator {
    struct ButtonCount: Equatable, Identifiable {
        let buttonID: UUID
        let label: String
        let colorHex: String
        let prompted: Int
        let spontaneous: Int

        var total: Int { prompted + spontaneous }
        var id: UUID { buttonID }
    }

    struct DayCount: Equatable, Identifiable {
        let day: Date
        let buttonID: UUID
        let label: String
        let colorHex: String
        let count: Int

        var id: String { "\(day.timeIntervalSinceReferenceDate)-\(buttonID.uuidString)" }
    }

    struct HourCell: Equatable, Identifiable {
        let hour: Int
        let buttonID: UUID
        let label: String
        let colorHex: String
        let count: Int

        var id: String { "\(hour)-\(buttonID.uuidString)" }
    }

    struct SequenceCount: Equatable, Identifiable {
        let labels: [String]
        let count: Int

        var id: String { labels.joined(separator: " > ") }
    }

    struct RepeatCount: Equatable, Identifiable {
        let buttonID: UUID
        let label: String
        let colorHex: String
        let count: Int

        var id: UUID { buttonID }
    }

    private struct Identity {
        let label: String
        let colorHex: String
    }

    /// One row per button, split by kind. Most pressed first, then alphabetical.
    static func countsPerButton(_ presses: [PressSnapshot]) -> [ButtonCount] {
        var prompted: [UUID: Int] = [:]
        var spontaneous: [UUID: Int] = [:]
        var identities: [UUID: Identity] = [:]
        for press in presses {
            identities[press.buttonID] = Identity(label: press.buttonLabel, colorHex: press.buttonColorHex)
            switch press.kind {
            case .prompted: prompted[press.buttonID, default: 0] += 1
            case .spontaneous: spontaneous[press.buttonID, default: 0] += 1
            }
        }
        return identities.map { id, identity in
            ButtonCount(buttonID: id, label: identity.label, colorHex: identity.colorHex,
                        prompted: prompted[id] ?? 0, spontaneous: spontaneous[id] ?? 0)
        }
        .sorted { a, b in
            if a.total != b.total { return a.total > b.total }
            return a.label.localizedStandardCompare(b.label) == .orderedAscending
        }
    }

    /// One row per local day and button. Oldest day first, then alphabetical.
    static func countsPerDay(_ presses: [PressSnapshot], calendar: Calendar = .current) -> [DayCount] {
        var counts: [Date: [UUID: Int]] = [:]
        var identities: [UUID: Identity] = [:]
        for press in presses {
            identities[press.buttonID] = Identity(label: press.buttonLabel, colorHex: press.buttonColorHex)
            counts[calendar.startOfDay(for: press.timestamp), default: [:]][press.buttonID, default: 0] += 1
        }
        var rows: [DayCount] = []
        for (day, byButton) in counts {
            for (buttonID, count) in byButton {
                guard let identity = identities[buttonID] else { continue }
                rows.append(DayCount(day: day, buttonID: buttonID, label: identity.label,
                                     colorHex: identity.colorHex, count: count))
            }
        }
        return rows.sorted { a, b in
            if a.day != b.day { return a.day < b.day }
            return a.label.localizedStandardCompare(b.label) == .orderedAscending
        }
    }

    /// One cell per hour of the day and button that has at least one press.
    static func hourHeatmap(_ presses: [PressSnapshot], calendar: Calendar = .current) -> [HourCell] {
        var counts: [UUID: [Int: Int]] = [:]
        var identities: [UUID: Identity] = [:]
        for press in presses {
            identities[press.buttonID] = Identity(label: press.buttonLabel, colorHex: press.buttonColorHex)
            let hour = calendar.component(.hour, from: press.timestamp)
            counts[press.buttonID, default: [:]][hour, default: 0] += 1
        }
        var cells: [HourCell] = []
        for (buttonID, byHour) in counts {
            guard let identity = identities[buttonID] else { continue }
            for (hour, count) in byHour {
                cells.append(HourCell(hour: hour, buttonID: buttonID, label: identity.label,
                                      colorHex: identity.colorHex, count: count))
            }
        }
        return cells.sorted { a, b in
            if a.label != b.label { return a.label.localizedStandardCompare(b.label) == .orderedAscending }
            return a.hour < b.hour
        }
    }

    /// Ordered runs of two or more different buttons. Most frequent first.
    static func sequenceCounts(_ sequences: [PressSequence]) -> [SequenceCount] {
        var counts: [[String]: Int] = [:]
        for sequence in sequences where Set(sequence.buttonIDs).count >= 2 {
            counts[sequence.labels, default: 0] += 1
        }
        return counts.map { SequenceCount(labels: $0.key, count: $0.value) }
            .sorted { a, b in
                if a.count != b.count { return a.count > b.count }
                return a.id.localizedStandardCompare(b.id) == .orderedAscending
            }
    }

    /// Runs of a single button pressed two or more times, counted per button. Most frequent first.
    static func repeatCounts(_ sequences: [PressSequence]) -> [RepeatCount] {
        var counts: [UUID: Int] = [:]
        var identities: [UUID: Identity] = [:]
        for sequence in sequences where sequence.presses.count >= 2 && Set(sequence.buttonIDs).count == 1 {
            guard let first = sequence.presses.first else { continue }
            identities[first.buttonID] = Identity(label: first.buttonLabel, colorHex: first.buttonColorHex)
            counts[first.buttonID, default: 0] += 1
        }
        return counts.compactMap { buttonID, count in
            guard let identity = identities[buttonID] else { return nil }
            return RepeatCount(buttonID: buttonID, label: identity.label,
                               colorHex: identity.colorHex, count: count)
        }
        .sorted { a, b in
            if a.count != b.count { return a.count > b.count }
            return a.label.localizedStandardCompare(b.label) == .orderedAscending
        }
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `scripts/test-app.sh`
Expected: `Executed 40 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(buttons): StatsAggregator counts presses per button, per day, per hour, and per sequence

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: Buttons tab shell, Manage section, and the RootTabView wiring

**Files:**
- Create: `App/Views/Buttons/ButtonsTabView.swift`, `App/Views/Buttons/ManageButtonsView.swift`, `App/Views/Buttons/ButtonFormView.swift`
- Modify: `App/RootTabView.swift` (one line)
- Test: `AppTests/ButtonsSectionTests.swift`

**Interfaces:**
- Consumes: `AACButton`, `Press`, `AACButton.canDelete`, `AACButton.pressCount` (Task 1); `Animal`, `ColorPalette.presets`, `ColorPalette.defaultHex`, `ColorPalette.color(_:)`, `ColorPalette.hex(_:)`, `@Environment(\.selectedAnimal)` (Plan A).
- Produces: `enum ButtonsSection: String, CaseIterable, Identifiable` with cases `log, history, stats, manage`, `var title: String`, and `static func initial(hasButtons: Bool) -> ButtonsSection`; `ButtonsTabView()`; `ManageButtonsView(animal: Animal)`; `ButtonFormView(button: AACButton?, animal: Animal)`. Task 5, 6, and 7 replace the stub bodies of `ButtonLogView(animal:)`, `ButtonHistoryView(animal:)`, and `ButtonStatsView(animal:)` created here.

- [ ] **Step 1: Write the failing test**

`AppTests/ButtonsSectionTests.swift`:
```swift
import XCTest
@testable import AnimalTracker

final class ButtonsSectionTests: XCTestCase {
    func testOpensOnManageWithNoButtonsAndOnLogOtherwise() {
        XCTAssertEqual(ButtonsSection.initial(hasButtons: false), .manage)
        XCTAssertEqual(ButtonsSection.initial(hasButtons: true), .log)
    }

    func testSectionOrderAndTitles() {
        XCTAssertEqual(ButtonsSection.allCases, [.log, .history, .stats, .manage])
        XCTAssertEqual(ButtonsSection.allCases.map(\.title), ["Log", "History", "Stats", "Manage"])
        XCTAssertEqual(ButtonsSection.log.id, "log")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test-app.sh`
Expected: build errors, `ButtonsSection` not found.

- [ ] **Step 3: Write the tab root and the three stubs**

`App/Views/Buttons/ButtonsTabView.swift`:
```swift
import SwiftData
import SwiftUI

enum ButtonsSection: String, CaseIterable, Identifiable {
    case log, history, stats, manage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .log: return "Log"
        case .history: return "History"
        case .stats: return "Stats"
        case .manage: return "Manage"
        }
    }

    /// With no buttons for this animal there is nothing to log, so the tab opens on Manage.
    static func initial(hasButtons: Bool) -> ButtonsSection { hasButtons ? .log : .manage }
}

/// Root of the Buttons tab. No NavigationStack here: RootTabView supplies one with the shared toolbar.
struct ButtonsTabView: View {
    @Environment(\.selectedAnimal) private var animal
    @Query(sort: [SortDescriptor(\AACButton.sortOrder), SortDescriptor(\AACButton.createdAt)])
    private var allButtons: [AACButton]
    @State private var section: ButtonsSection = .log

    var body: some View {
        Group {
            if let animal {
                VStack(spacing: 0) {
                    Picker("Section", selection: $section) {
                        ForEach(ButtonsSection.allCases) { section in
                            Text(section.title).tag(section)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.vertical, 8)

                    switch section {
                    case .log: ButtonLogView(animal: animal)
                    case .history: ButtonHistoryView(animal: animal)
                    case .stats: ButtonStatsView(animal: animal)
                    case .manage: ManageButtonsView(animal: animal)
                    }
                }
                .onAppear { route(for: animal) }
                .onChange(of: animal.id) { _, _ in route(for: animal) }
            } else {
                ContentUnavailableView {
                    Label("No animal selected", systemImage: "pawprint")
                } description: {
                    Text("Add an animal from the menu at the top left, then come back to log button presses.")
                }
            }
        }
    }

    private func route(for animal: Animal) {
        let hasButtons = allButtons.contains { $0.animal?.id == animal.id && !$0.isArchived }
        section = ButtonsSection.initial(hasButtons: hasButtons)
    }
}
```

Temporary stubs so this task compiles. Task 5, 6, and 7 replace each file's contents.

`App/Views/Buttons/ButtonLogView.swift`:
```swift
import SwiftUI

struct ButtonLogView: View {
    let animal: Animal
    var body: some View { Text("Log for \(animal.name)") }
}
```

`App/Views/Buttons/ButtonHistoryView.swift`:
```swift
import SwiftUI

struct ButtonHistoryView: View {
    let animal: Animal
    var body: some View { Text("History for \(animal.name)") }
}
```

`App/Views/Buttons/ButtonStatsView.swift`:
```swift
import SwiftUI

struct ButtonStatsView: View {
    let animal: Animal
    var body: some View { Text("Stats for \(animal.name)") }
}
```

- [ ] **Step 4: Write the add and edit form**

`App/Views/Buttons/ButtonFormView.swift`:
```swift
import SwiftData
import SwiftUI

/// Add or rename and recolor one button. Presented as a sheet from Manage.
struct ButtonFormView: View {
    let button: AACButton?
    let animal: Animal

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \AACButton.sortOrder) private var allButtons: [AACButton]

    @State private var label = ""
    @State private var colorHex = ColorPalette.defaultHex
    @State private var customColor = ColorPalette.color(ColorPalette.defaultHex)
    @State private var errorMessage: String?

    /// Other buttons of this animal, archived ones included, so a label is never reused.
    private var siblings: [AACButton] {
        allButtons.filter { $0.animal?.id == animal.id && $0.id != button?.id }
    }

    private var trimmedLabel: String { label.trimmingCharacters(in: .whitespaces) }

    private var isDuplicate: Bool {
        !trimmedLabel.isEmpty && siblings.contains { $0.label.caseInsensitiveCompare(trimmedLabel) == .orderedSame }
    }

    private var canSave: Bool { !trimmedLabel.isEmpty && !isDuplicate }

    var body: some View {
        Form {
            Section("Label") {
                TextField("The word on the button", text: $label)
                    .autocorrectionDisabled()
                if isDuplicate {
                    Text("\(animal.name) already has a button called \(trimmedLabel).")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            Section("Color") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                    ForEach(ColorPalette.presets, id: \.self) { hex in
                        Circle()
                            .fill(ColorPalette.color(hex))
                            .frame(width: 36, height: 36)
                            .overlay(Circle().stroke(Color.primary, lineWidth: colorHex == hex ? 3 : 0))
                            .onTapGesture { colorHex = hex }
                            .accessibilityLabel(hex)
                            .accessibilityAddTraits(colorHex == hex ? [.isButton, .isSelected] : .isButton)
                    }
                }
                .padding(.vertical, 4)
                ColorPicker("Custom", selection: $customColor, supportsOpacity: false)
                    .onChange(of: customColor) { _, color in colorHex = ColorPalette.hex(color) }
            }
            Section("Preview") {
                Text(trimmedLabel.isEmpty ? "Label" : trimmedLabel)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(ColorPalette.contrastingText(on: colorHex))
                    .frame(maxWidth: .infinity, minHeight: 88)
                    .background(ColorPalette.color(colorHex), in: RoundedRectangle(cornerRadius: 16))
                    .listRowBackground(Color.clear)
            }
        }
        .navigationTitle(button == nil ? "Add Button" : "Edit Button")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let button {
                label = button.label
                colorHex = button.colorHex
                customColor = ColorPalette.color(button.colorHex)
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(!canSave) }
        }
        .alert("Could not save", isPresented: Binding(get: { errorMessage != nil },
                                                     set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func save() {
        let target: AACButton
        if let button {
            target = button
        } else {
            let next = (siblings.map(\.sortOrder).max() ?? -1) + 1
            let created = AACButton(label: trimmedLabel, colorHex: colorHex, sortOrder: next)
            context.insert(created)
            created.animal = animal
            target = created
        }
        target.label = trimmedLabel
        target.colorHex = colorHex
        do {
            try context.save()
            dismiss()
        } catch {
            if button == nil { context.delete(target) }
            errorMessage = error.localizedDescription
        }
    }
}
```

- [ ] **Step 5: Write the Manage section**

`App/Views/Buttons/ManageButtonsView.swift`:
```swift
import SwiftData
import SwiftUI

/// The Manage section of the Buttons tab: the animal's buttons plus the two logging settings.
struct ManageButtonsView: View {
    let animal: Animal

    @Environment(\.modelContext) private var context
    @AppStorage("sequenceWindowSeconds") private var sequenceWindowSeconds = 10
    @AppStorage("defaultPressKind") private var defaultPressKindRaw = PressKind.spontaneous.rawValue
    @Query(sort: [SortDescriptor(\AACButton.sortOrder), SortDescriptor(\AACButton.createdAt)])
    private var allButtons: [AACButton]

    @State private var showAdd = false
    @State private var editing: AACButton?
    @State private var blockedMessage: String?
    @State private var editMode: EditMode = .inactive

    private var mine: [AACButton] { allButtons.filter { $0.animal?.id == animal.id } }
    private var active: [AACButton] { mine.filter { !$0.isArchived } }
    private var archived: [AACButton] { mine.filter(\.isArchived) }

    private var defaultKind: Binding<PressKind> {
        Binding(get: { PressKind(rawValue: defaultPressKindRaw) ?? .spontaneous },
                set: { defaultPressKindRaw = $0.rawValue })
    }

    var body: some View {
        List {
            Section {
                ForEach(active) { button in
                    row(button)
                        .swipeActions(edge: .trailing) {
                            Button("Delete", role: .destructive) { delete(button) }
                            Button("Archive") { setArchived(button, true) }.tint(.orange)
                        }
                }
                .onMove(perform: move)

                Button { showAdd = true } label: {
                    Label("Add button", systemImage: "plus")
                }
            } header: {
                HStack {
                    Text(active.isEmpty ? "No buttons yet" : "Buttons")
                    Spacer()
                    if active.count > 1 {
                        Button(editMode == .active ? "Done" : "Reorder") {
                            withAnimation { editMode = editMode == .active ? .inactive : .active }
                        }
                        .font(.caption)
                        .textCase(nil)
                    }
                }
            } footer: {
                if active.isEmpty {
                    Text("Add one button per physical button you have recorded for \(animal.name).")
                }
            }

            if !archived.isEmpty {
                Section("Archived") {
                    ForEach(archived) { button in
                        row(button)
                            .swipeActions(edge: .trailing) {
                                Button("Delete", role: .destructive) { delete(button) }
                                Button("Unarchive") { setArchived(button, false) }.tint(.green)
                            }
                    }
                }
            }

            Section {
                Stepper("Sequence window: \(sequenceWindowSeconds)s", value: $sequenceWindowSeconds, in: 2...120)
                Picker("Default press kind", selection: defaultKind) {
                    Text("Spontaneous").tag(PressKind.spontaneous)
                    Text("Prompted").tag(PressKind.prompted)
                }
            } header: {
                Text("Logging")
            } footer: {
                Text("Presses closer together than the sequence window are shown as one sequence in History.")
            }
        }
        .environment(\.editMode, $editMode)
        .sheet(isPresented: $showAdd) {
            NavigationStack { ButtonFormView(button: nil, animal: animal) }
        }
        .sheet(item: $editing) { button in
            NavigationStack { ButtonFormView(button: button, animal: animal) }
        }
        .alert("Cannot delete", isPresented: Binding(get: { blockedMessage != nil },
                                                    set: { if !$0 { blockedMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(blockedMessage ?? "")
        }
    }

    private func row(_ button: AACButton) -> some View {
        Button { editing = button } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(ColorPalette.color(button.colorHex))
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(button.label).font(.headline).foregroundStyle(.primary)
                    Text(button.pressCount == 1 ? "1 press" : "\(button.pressCount) presses")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if button.isArchived {
                    Text("Archived").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func move(from source: IndexSet, to destination: Int) {
        var ordered = active
        ordered.move(fromOffsets: source, toOffset: destination)
        for (index, button) in ordered.enumerated() { button.sortOrder = index }
        do {
            try context.save()
        } catch {
            blockedMessage = error.localizedDescription
        }
    }

    private func setArchived(_ button: AACButton, _ archived: Bool) {
        button.isArchived = archived
        do {
            try context.save()
        } catch {
            button.isArchived = !archived
            blockedMessage = error.localizedDescription
        }
    }

    /// Delete is allowed only with zero presses; otherwise the user archives instead.
    private func delete(_ button: AACButton) {
        guard button.canDelete else {
            let count = button.pressCount
            blockedMessage = "\(button.label) has \(count == 1 ? "1 press" : "\(count) presses"). Archive it instead."
            return
        }
        context.delete(button)
        do {
            try context.save()
        } catch {
            blockedMessage = error.localizedDescription
        }
    }
}
```

- [ ] **Step 6: Wire the tab**

```bash
sed -i '' 's|tab("Buttons", "square.grid.2x2") { Text("Buttons") }|tab("Buttons", "square.grid.2x2") { ButtonsTabView() }|' App/RootTabView.swift
grep -n 'ButtonsTabView()' App/RootTabView.swift
```
Expected: one line printed, inside the `TabView` body. No other line of `RootTabView.swift` changes.

- [ ] **Step 7: Run tests and look at the app**

Run: `scripts/test-app.sh`
Expected: `Executed 42 tests, with 0 failures`.

Run: `scripts/run-sim.sh`, then in the simulator add an animal named Juniper (species horse), open the Buttons tab, and add two buttons: "Out" with the first palette color and "Treat" with the second. Read `build/screenshot.png`. Expected: the Buttons tab opens on Manage because the animal has no buttons; after adding, both rows show a color swatch, the label, and "0 presses"; the segmented control reads Log, History, Stats, Manage; the nav bar still shows the animal switcher on the left and the microphone and gear on the right, with no second nav bar.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat(buttons): Buttons tab shell with Manage section, button form, and RootTabView wiring

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: Log section with one-tap logging, undo toast, and the long-press note sheet

**Files:**
- Create: `App/Logic/LogRules.swift`, `App/Views/Buttons/PressNoteSheet.swift`
- Modify: `App/Views/Buttons/ButtonLogView.swift` (replace the stub from Task 4)
- Test: `AppTests/LogRulesTests.swift`

**Interfaces:**
- Consumes: `AACButton`, `Press`, `PressKind`, `ColorPalette`, `ButtonsTabView`'s call `ButtonLogView(animal:)`.
- Produces: `LogRules.noteWindow: TimeInterval` (60), `LogRules.annotatesExistingPress(latestPressAt:now:window:) -> Bool`, `LogRules.toastText(label:kind:) -> String`; `PressNoteSheet(press: Press)`; the real `ButtonLogView(animal: Animal)`.

- [ ] **Step 1: Write the failing test**

`AppTests/LogRulesTests.swift`:
```swift
import XCTest
@testable import AnimalTracker

final class LogRulesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testNoteWindowIsSixtySeconds() {
        XCTAssertEqual(LogRules.noteWindow, 60)
    }

    func testAnnotatesOnlyAPressFromTheLastSixtySeconds() {
        XCTAssertTrue(LogRules.annotatesExistingPress(latestPressAt: now, now: now))
        XCTAssertTrue(LogRules.annotatesExistingPress(latestPressAt: now.addingTimeInterval(-59), now: now))
        XCTAssertTrue(LogRules.annotatesExistingPress(latestPressAt: now.addingTimeInterval(-60), now: now))
        XCTAssertFalse(LogRules.annotatesExistingPress(latestPressAt: now.addingTimeInterval(-60.5), now: now))
        XCTAssertFalse(LogRules.annotatesExistingPress(latestPressAt: now.addingTimeInterval(-3600), now: now))
        XCTAssertFalse(LogRules.annotatesExistingPress(latestPressAt: nil, now: now))
    }

    func testAPressTimestampedInTheFutureIsNotAnnotated() {
        XCTAssertFalse(LogRules.annotatesExistingPress(latestPressAt: now.addingTimeInterval(5), now: now))
    }

    func testToastTextNamesTheButtonAndKind() {
        XCTAssertEqual(LogRules.toastText(label: "Out", kind: .spontaneous), "Logged Out (spontaneous)")
        XCTAssertEqual(LogRules.toastText(label: "Treat", kind: .prompted), "Logged Treat (prompted)")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test-app.sh`
Expected: build errors, `LogRules` not found.

- [ ] **Step 3: Implement the rules**

`App/Logic/LogRules.swift`:
```swift
import Foundation

/// The two rules the Log grid follows, kept out of the view so they can be tested.
enum LogRules {
    /// A long press within this many seconds of a button's last press annotates that press
    /// instead of logging a new one (spec, Buttons tab / Log).
    static let noteWindow: TimeInterval = 60

    static func annotatesExistingPress(latestPressAt: Date?, now: Date,
                                       window: TimeInterval = noteWindow) -> Bool {
        guard let latestPressAt else { return false }
        let age = now.timeIntervalSince(latestPressAt)
        return age >= 0 && age <= window
    }

    /// "Logged Out (spontaneous)"
    static func toastText(label: String, kind: PressKind) -> String {
        "Logged \(label) (\(kind.rawValue))"
    }
}
```

- [ ] **Step 4: Implement the note sheet**

`App/Views/Buttons/PressNoteSheet.swift`:
```swift
import SwiftData
import SwiftUI

/// Reached by long-pressing a tile in the Log grid. Adds or edits the note on one press.
struct PressNoteSheet: View {
    let press: Press

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("Note") {
                TextField("What happened?", text: $note, axis: .vertical)
                    .lineLimit(3...6)
            }
            Section {
                LabeledContent("Button", value: press.button?.label ?? "Unknown")
                LabeledContent("Logged", value: press.timestamp.formatted(date: .omitted, time: .shortened))
                LabeledContent("Kind", value: press.kind.rawValue.capitalized)
            }
        }
        .navigationTitle("Press Note")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { note = press.note ?? "" }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
        }
        .alert("Could not save", isPresented: Binding(get: { errorMessage != nil },
                                                     set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func save() {
        let previousNote = press.note
        let previousEdit = press.editedAt
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        press.note = trimmed.isEmpty ? nil : trimmed
        press.editedAt = Date()
        do {
            try context.save()
            dismiss()
        } catch {
            press.note = previousNote
            press.editedAt = previousEdit
            errorMessage = error.localizedDescription
        }
    }
}
```

- [ ] **Step 5: Implement the Log grid**

`App/Views/Buttons/ButtonLogView.swift` (replace the stub):
```swift
import SwiftData
import SwiftUI

/// The Log section: one tap on a tile records a press.
struct ButtonLogView: View {
    let animal: Animal

    @Environment(\.modelContext) private var context
    @AppStorage("defaultPressKind") private var defaultPressKindRaw = PressKind.spontaneous.rawValue
    @Query(sort: [SortDescriptor(\AACButton.sortOrder), SortDescriptor(\AACButton.createdAt)])
    private var allButtons: [AACButton]
    @Query(sort: [SortDescriptor(\Press.timestamp, order: .reverse)])
    private var allPresses: [Press]

    @State private var kind: PressKind = .spontaneous
    @State private var toast: LoggedToast?
    @State private var toastTask: Task<Void, Never>?
    @State private var notePress: Press?
    @State private var errorMessage: String?

    /// One toast at a time, naming the press it can undo.
    struct LoggedToast: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let pressID: UUID
    }

    private var buttons: [AACButton] {
        allButtons.filter { $0.animal?.id == animal.id && !$0.isArchived }
    }

    private var defaultKind: PressKind { PressKind(rawValue: defaultPressKindRaw) ?? .spontaneous }

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ZStack(alignment: .bottom) {
            if buttons.isEmpty {
                ContentUnavailableView {
                    Label("No buttons to log", systemImage: "square.grid.2x2")
                } description: {
                    Text("Every button for \(animal.name) is archived. Open Manage to add one or bring one back.")
                }
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        Picker("Press kind", selection: $kind) {
                            Text("Spontaneous").tag(PressKind.spontaneous)
                            Text("Prompted").tag(PressKind.prompted)
                        }
                        .pickerStyle(.segmented)

                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(buttons) { button in tile(button) }
                        }
                    }
                    .padding()
                    .padding(.bottom, 64)
                }
            }

            if let toast { toastView(toast) }
        }
        .onAppear { kind = defaultKind }
        .sheet(item: $notePress) { press in
            NavigationStack { PressNoteSheet(press: press) }
                .presentationDetents([.medium, .large])
        }
        .alert("Could not save", isPresented: Binding(get: { errorMessage != nil },
                                                     set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    /// Tap logs a press; long press opens the note sheet. Exclusively, so only one of the two fires.
    private func tile(_ button: AACButton) -> some View {
        Text(button.label)
            .font(.title2.weight(.semibold))
            .multilineTextAlignment(.center)
            .foregroundStyle(ColorPalette.contrastingText(on: button.colorHex))
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 104)
            .background(ColorPalette.color(button.colorHex), in: RoundedRectangle(cornerRadius: 16))
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .gesture(
                LongPressGesture(minimumDuration: 0.5)
                    .onEnded { _ in annotate(button) }
                    .exclusively(before: TapGesture().onEnded { log(button, openNote: false) })
            )
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Log \(button.label)")
            .accessibilityAction(named: "Add a note") { annotate(button) }
    }

    private func toastView(_ toast: LoggedToast) -> some View {
        HStack(spacing: 12) {
            Text(toast.text).font(.subheadline)
            Spacer(minLength: 8)
            Button("Undo") { undo(toast) }
                .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: Capsule())
        .shadow(radius: 4, y: 2)
        .padding(.horizontal)
        .padding(.bottom, 12)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func log(_ button: AACButton, openNote: Bool) {
        let press = Press(timestamp: Date(), kind: kind)
        context.insert(press)
        press.button = button
        press.animal = animal
        do {
            try context.save()
        } catch {
            context.delete(press)
            errorMessage = error.localizedDescription
            return
        }

        let logged = press.kind
        kind = defaultKind
        if openNote {
            cancelToast()
            notePress = press
        } else {
            showToast(LoggedToast(text: LogRules.toastText(label: button.label, kind: logged), pressID: press.id))
        }
    }

    /// Long press: annotate the last press of this button if it is less than a minute old, else log one.
    private func annotate(_ button: AACButton) {
        let latest = allPresses.first { $0.button?.id == button.id && $0.animal?.id == animal.id }
        if let latest, LogRules.annotatesExistingPress(latestPressAt: latest.timestamp, now: Date()) {
            cancelToast()
            notePress = latest
        } else {
            log(button, openNote: true)
        }
    }

    private func showToast(_ new: LoggedToast) {
        toastTask?.cancel()
        withAnimation { toast = new }
        toastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation { toast = nil }
        }
    }

    private func cancelToast() {
        toastTask?.cancel()
        toastTask = nil
        withAnimation { toast = nil }
    }

    /// Undo covers only the last logged press (spec, Data handling).
    private func undo(_ toast: LoggedToast) {
        cancelToast()
        guard let press = allPresses.first(where: { $0.id == toast.pressID }) else { return }
        context.delete(press)
        do {
            try context.save()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
```

- [ ] **Step 6: Run to verify pass**

Run: `scripts/test-app.sh`
Expected: `Executed 46 tests, with 0 failures`.

- [ ] **Step 7: Look at the app**

Run: `scripts/run-sim.sh`. In the simulator, on the Buttons tab with Juniper's two buttons: tap Out, read `build/screenshot.png` within three seconds and confirm the toast reads "Logged Out (spontaneous)" with an Undo button; tap Undo and confirm the toast goes away. Tap Prompted, tap Treat, and confirm the kind toggle snaps back to Spontaneous. Long-press Treat within a minute and confirm the note sheet opens on that same press rather than logging a second one; the Kind row reads Prompted. Long-press Out after more than a minute and confirm the sheet opens on a freshly logged press.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat(buttons): one-tap press logging with undo toast and long-press note sheet

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: History section with day sections, sequence rows, delete, and edit

**Files:**
- Create: `App/Logic/HistoryGrouping.swift`, `App/Views/Buttons/PressEditView.swift`
- Modify: `App/Views/Buttons/ButtonHistoryView.swift` (replace the stub from Task 4)
- Test: `AppTests/HistoryGroupingTests.swift`

**Interfaces:**
- Consumes: `PressSnapshot` (Task 1), `PressSequence` and `Sequencer.group(_:window:)` (Task 2), `@AppStorage("sequenceWindowSeconds")`.
- Produces: `struct PressDaySection: Equatable, Identifiable` with `day: Date`, `sequences: [PressSequence]`, `id: Date`; `HistoryGrouping.sections(_ sequences: [PressSequence], calendar: Calendar) -> [PressDaySection]`; `PressEditView(press: Press)`; the real `ButtonHistoryView(animal: Animal)`.

- [ ] **Step 1: Write the failing test**

`AppTests/HistoryGroupingTests.swift`:
```swift
import XCTest
@testable import AnimalTracker

final class HistoryGroupingTests: XCTestCase {
    private let out = UUID()
    private let treat = UUID()
    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }

    private func press(_ buttonID: UUID, _ label: String, _ offset: TimeInterval) -> PressSnapshot {
        PressSnapshot(id: UUID(), timestamp: base.addingTimeInterval(offset), buttonID: buttonID,
                      buttonLabel: label, buttonColorHex: "#2A78D6", kind: .spontaneous, note: nil)
    }

    func testEmptyInputMakesNoSections() {
        XCTAssertTrue(HistoryGrouping.sections([], calendar: utc).isEmpty)
    }

    func testNewestDayFirstAndNewestSequenceFirstInsideADay() {
        let day = 60.0 * 60 * 24
        let sequences = Sequencer.group([
            press(out, "Out", 0),
            press(treat, "Treat", 300),
            press(out, "Out", day),
        ], window: 10)
        let sections = HistoryGrouping.sections(sequences, calendar: utc)

        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(sections[0].day, utc.startOfDay(for: base.addingTimeInterval(day)))
        XCTAssertEqual(sections[0].sequences.map(\.labels), [["Out"]])
        XCTAssertEqual(sections[1].day, utc.startOfDay(for: base))
        XCTAssertEqual(sections[1].sequences.map(\.labels), [["Treat"], ["Out"]])
        XCTAssertEqual(sections[0].id, sections[0].day)
    }

    func testASequenceBelongsToTheDayOfItsFirstPress() {
        // 22:13:20 UTC plus 6000 s crosses local midnight; the run stays on the earlier day.
        let sequences = Sequencer.group([press(out, "Out", 0), press(treat, "Treat", 6_000)], window: 10_000)
        let sections = HistoryGrouping.sections(sequences, calendar: utc)
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].day, utc.startOfDay(for: base))
        XCTAssertEqual(sections[0].sequences[0].labels, ["Out", "Treat"])
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test-app.sh`
Expected: build errors, `HistoryGrouping` and `PressDaySection` not found.

- [ ] **Step 3: Implement the grouping**

`App/Logic/HistoryGrouping.swift`:
```swift
import Foundation

/// One calendar day of sequences for the History list.
struct PressDaySection: Equatable, Identifiable {
    let day: Date
    let sequences: [PressSequence]

    var id: Date { day }
}

enum HistoryGrouping {
    /// Newest day first, newest sequence first inside each day.
    /// A sequence belongs to the day its first press happened on, even if it crosses midnight.
    static func sections(_ sequences: [PressSequence], calendar: Calendar = .current) -> [PressDaySection] {
        var byDay: [Date: [PressSequence]] = [:]
        for sequence in sequences {
            byDay[calendar.startOfDay(for: sequence.start), default: []].append(sequence)
        }
        return byDay.keys.sorted(by: >).map { day in
            PressDaySection(day: day, sequences: (byDay[day] ?? []).sorted { $0.start > $1.start })
        }
    }
}
```

- [ ] **Step 4: Implement the edit screen**

`App/Views/Buttons/PressEditView.swift`:
```swift
import SwiftData
import SwiftUI

/// Edit one press: timestamp, kind, note. Reached by tapping a row in History.
struct PressEditView: View {
    let press: Press

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var timestamp = Date()
    @State private var kind: PressKind = .spontaneous
    @State private var note = ""
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Button", value: press.button?.label ?? "Unknown")
            }
            Section {
                DatePicker("Time", selection: $timestamp)
                Picker("Kind", selection: $kind) {
                    Text("Spontaneous").tag(PressKind.spontaneous)
                    Text("Prompted").tag(PressKind.prompted)
                }
                .pickerStyle(.segmented)
            }
            Section("Note") {
                TextField("What happened?", text: $note, axis: .vertical)
                    .lineLimit(3...6)
            }
            if let editedAt = press.editedAt {
                Section {
                    LabeledContent("Last edited", value: editedAt.formatted(date: .abbreviated, time: .shortened))
                }
            }
        }
        .navigationTitle("Edit Press")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            timestamp = press.timestamp
            kind = press.kind
            note = press.note ?? ""
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
        }
        .alert("Could not save", isPresented: Binding(get: { errorMessage != nil },
                                                     set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func save() {
        let previous = (timestamp: press.timestamp, kind: press.kind, note: press.note, editedAt: press.editedAt)
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        press.timestamp = timestamp
        press.kind = kind
        press.note = trimmed.isEmpty ? nil : trimmed
        press.editedAt = Date()
        do {
            try context.save()
            dismiss()
        } catch {
            press.timestamp = previous.timestamp
            press.kind = previous.kind
            press.note = previous.note
            press.editedAt = previous.editedAt
            errorMessage = error.localizedDescription
        }
    }
}
```

- [ ] **Step 5: Implement the History list**

`App/Views/Buttons/ButtonHistoryView.swift` (replace the stub):
```swift
import SwiftData
import SwiftUI

/// The History section: presses newest first, sectioned by day, grouped into sequences.
struct ButtonHistoryView: View {
    let animal: Animal

    @Environment(\.modelContext) private var context
    @AppStorage("sequenceWindowSeconds") private var sequenceWindowSeconds = 10
    @Query(sort: [SortDescriptor(\Press.timestamp, order: .reverse)])
    private var allPresses: [Press]

    @State private var editing: Press?
    @State private var errorMessage: String?

    private var presses: [Press] {
        allPresses.filter { $0.animal?.id == animal.id && $0.button != nil }
    }

    private var pressesByID: [UUID: Press] {
        Dictionary(presses.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private var sections: [PressDaySection] {
        let sequences = Sequencer.group(presses.compactMap(PressSnapshot.init),
                                        window: TimeInterval(sequenceWindowSeconds))
        return HistoryGrouping.sections(sequences)
    }

    var body: some View {
        List {
            ForEach(sections) { section in
                Section(section.day.formatted(date: .complete, time: .omitted)) {
                    ForEach(section.sequences) { sequence in
                        sequenceRow(sequence)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if sections.isEmpty {
                ContentUnavailableView {
                    Label("No presses yet", systemImage: "clock")
                } description: {
                    Text("Presses you log for \(animal.name) show up here, grouped into sequences.")
                }
            }
        }
        .sheet(item: $editing) { press in
            NavigationStack { PressEditView(press: press) }
        }
        .alert("Could not save", isPresented: Binding(get: { errorMessage != nil },
                                                     set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func sequenceRow(_ sequence: PressSequence) -> some View {
        if sequence.isSingle, let snapshot = sequence.presses.first {
            pressRow(snapshot)
        } else {
            DisclosureGroup {
                ForEach(sequence.presses) { snapshot in
                    pressRow(snapshot)
                }
            } label: {
                HStack(spacing: 10) {
                    HStack(spacing: -4) {
                        ForEach(sequence.presses) { snapshot in
                            Circle()
                                .fill(ColorPalette.color(snapshot.buttonColorHex))
                                .frame(width: 12, height: 12)
                                .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 1))
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sequence.labels.joined(separator: " \u{2192} "))
                            .font(.body)
                        Text("\(sequence.presses.count) presses at \(sequence.start.formatted(date: .omitted, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func pressRow(_ snapshot: PressSnapshot) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(ColorPalette.color(snapshot.buttonColorHex))
                .frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.buttonLabel).font(.body)
                if let note = snapshot.note, !note.isEmpty {
                    Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(snapshot.kind == .prompted ? "Prompted" : "Spontaneous")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(snapshot.kind == .prompted ? Color.orange.opacity(0.2) : Color.green.opacity(0.2),
                            in: Capsule())
            Text(snapshot.timestamp.formatted(date: .omitted, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .contentShape(Rectangle())
        .onTapGesture { editing = pressesByID[snapshot.id] }
        .swipeActions(edge: .trailing) {
            Button("Delete", role: .destructive) { delete(snapshot.id) }
        }
    }

    private func delete(_ id: UUID) {
        guard let press = pressesByID[id] else { return }
        context.delete(press)
        do {
            try context.save()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
```

- [ ] **Step 6: Run to verify pass**

Run: `scripts/test-app.sh`
Expected: `Executed 49 tests, with 0 failures`.

- [ ] **Step 7: Look at the app**

Run: `scripts/run-sim.sh`. On the Log section tap Out then Treat within ten seconds, then wait, then tap Out once more. Switch to History and read `build/screenshot.png`. Expected: one day section headed with today's date; the newest row is a single "Out" with a color dot, a Spontaneous badge, and a time; below it a row reading "Out → Treat" with a disclosure arrow that expands to the two individual presses. Swipe a single press left and confirm Delete removes it. Tap a press and confirm the edit sheet opens with its time, kind, and note.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat(buttons): History section with day sections, sequence rows, swipe delete, and press editing

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: Stats section with the range picker, three charts, and the two tables

**Files:**
- Create: `App/Logic/StatsRange.swift`, `App/Views/Buttons/ButtonChartLegends.swift`
- Modify: `App/Views/Buttons/ButtonStatsView.swift` (replace the stub from Task 4)
- Test: `AppTests/StatsRangeTests.swift`

**Interfaces:**
- Consumes: `PressSnapshot` (Task 1); `Sequencer.group(_:window:)` and `PressSequence` (Task 2); `StatsAggregator.countsPerButton/countsPerDay/hourHeatmap/sequenceCounts/repeatCounts` with `ButtonCount`, `DayCount`, `HourCell`, `SequenceCount`, `RepeatCount` (Task 3); `@AppStorage("sequenceWindowSeconds")`.
- Produces: `enum StatsRange: String, CaseIterable, Identifiable` with cases `week, month, all`, `title`, `days`, `StatsRange.start(for:now:calendar:) -> Date?`, `StatsRange.filter(_:range:now:calendar:) -> [PressSnapshot]`; `ButtonColorLegend(entries: [ButtonColorLegend.Entry])`, `PressKindLegend()`, `HeatmapIntensityLegend()`; the real `ButtonStatsView(animal: Animal)`.

- [ ] **Step 1: Write the failing test**

`AppTests/StatsRangeTests.swift`:
```swift
import XCTest
@testable import AnimalTracker

final class StatsRangeTests: XCTestCase {
    private let button = UUID()
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }

    private func press(_ daysAgo: Double) -> PressSnapshot {
        PressSnapshot(id: UUID(), timestamp: now.addingTimeInterval(-daysAgo * 86_400), buttonID: button,
                      buttonLabel: "Out", buttonColorHex: "#2A78D6", kind: .spontaneous, note: nil)
    }

    func testTitlesAndOrder() {
        XCTAssertEqual(StatsRange.allCases, [.week, .month, .all])
        XCTAssertEqual(StatsRange.allCases.map(\.title), ["7 days", "30 days", "All"])
        XCTAssertEqual(StatsRange.week.days, 7)
        XCTAssertEqual(StatsRange.month.days, 30)
        XCTAssertNil(StatsRange.all.days)
    }

    func testStartIsMidnightOfTheFirstDayInTheRange() {
        let today = utc.startOfDay(for: now)
        XCTAssertEqual(StatsRange.start(for: .week, now: now, calendar: utc),
                       today.addingTimeInterval(-6 * 86_400))
        XCTAssertEqual(StatsRange.start(for: .month, now: now, calendar: utc),
                       today.addingTimeInterval(-29 * 86_400))
        XCTAssertNil(StatsRange.start(for: .all, now: now, calendar: utc))
    }

    func testFilterKeepsPressesOnOrAfterTheStartAndAllKeepsEverything() {
        let presses = [press(0), press(3), press(6.5), press(10), press(400)]
        XCTAssertEqual(StatsRange.filter(presses, range: .week, now: now, calendar: utc).count, 3)
        XCTAssertEqual(StatsRange.filter(presses, range: .month, now: now, calendar: utc).count, 4)
        XCTAssertEqual(StatsRange.filter(presses, range: .all, now: now, calendar: utc).count, 5)
        XCTAssertTrue(StatsRange.filter([], range: .week, now: now, calendar: utc).isEmpty)
    }
}
```

The 6.5-day-old press falls on the seventh day back, whose midnight is the range start, so the week keeps three of the five.

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test-app.sh`
Expected: build errors, `StatsRange` not found.

- [ ] **Step 3: Implement the range**

`App/Logic/StatsRange.swift`:
```swift
import Foundation

/// The Stats range picker: 7 days, 30 days, All.
enum StatsRange: String, CaseIterable, Identifiable {
    case week, month, all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .week: return "7 days"
        case .month: return "30 days"
        case .all: return "All"
        }
    }

    /// Days covered, today included. Nil means no lower bound.
    var days: Int? {
        switch self {
        case .week: return 7
        case .month: return 30
        case .all: return nil
        }
    }

    /// Local midnight of the first day in the range, or nil for All.
    static func start(for range: StatsRange, now: Date, calendar: Calendar = .current) -> Date? {
        guard let days = range.days else { return nil }
        return calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: now))
    }

    static func filter(_ presses: [PressSnapshot], range: StatsRange, now: Date,
                       calendar: Calendar = .current) -> [PressSnapshot] {
        guard let start = start(for: range, now: now, calendar: calendar) else { return presses }
        return presses.filter { $0.timestamp >= start }
    }
}
```

- [ ] **Step 4: Implement the legends**

`App/Views/Buttons/ButtonChartLegends.swift`:
```swift
import SwiftUI

/// Which color belongs to which button. Shown under charts that color marks directly.
struct ButtonColorLegend: View {
    struct Entry: Identifiable, Equatable {
        let label: String
        let colorHex: String

        var id: String { label }
    }

    let entries: [Entry]

    var body: some View {
        if entries.count >= 2 {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { swatches }
                VStack(alignment: .leading, spacing: 4) { swatches }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var swatches: some View {
        ForEach(entries) { entry in
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(ColorPalette.color(entry.colorHex))
                    .frame(width: 14, height: 10)
                Text(entry.label)
            }
        }
    }
}

/// Explains the opacity split inside each per-button bar.
struct PressKindLegend: View {
    var body: some View {
        HStack(spacing: 16) {
            item(opacity: 1, label: "Spontaneous")
            item(opacity: 0.5, label: "Prompted")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func item(opacity: Double, label: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.secondary.opacity(opacity))
                .frame(width: 14, height: 10)
            Text(label)
        }
    }
}

/// Explains that a darker heatmap cell means more presses in that hour.
struct HeatmapIntensityLegend: View {
    private let steps: [Double] = [0.15, 0.43, 0.71, 1.0]

    var body: some View {
        HStack(spacing: 6) {
            Text("Fewer")
            ForEach(steps, id: \.self) { step in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(step))
                    .frame(width: 14, height: 10)
            }
            Text("More")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
```

- [ ] **Step 5: Implement the Stats section**

`App/Views/Buttons/ButtonStatsView.swift` (replace the stub):
```swift
import Charts
import SwiftData
import SwiftUI

/// The Stats section: three charts and two tables over the selected range.
struct ButtonStatsView: View {
    let animal: Animal

    @AppStorage("sequenceWindowSeconds") private var sequenceWindowSeconds = 10
    @Query(sort: [SortDescriptor(\Press.timestamp)]) private var allPresses: [Press]
    @State private var range: StatsRange = .week

    private var snapshots: [PressSnapshot] {
        let mine = allPresses.filter { $0.animal?.id == animal.id }.compactMap(PressSnapshot.init)
        return StatsRange.filter(mine, range: range, now: Date())
    }

    private var perButton: [StatsAggregator.ButtonCount] { StatsAggregator.countsPerButton(snapshots) }
    private var perDay: [StatsAggregator.DayCount] { StatsAggregator.countsPerDay(snapshots) }
    private var heatmap: [StatsAggregator.HourCell] { StatsAggregator.hourHeatmap(snapshots) }
    private var sequences: [PressSequence] {
        Sequencer.group(snapshots, window: TimeInterval(sequenceWindowSeconds))
    }

    /// One color per label, in the order the per-button chart uses. Labels are unique per animal.
    private var legendEntries: [ButtonColorLegend.Entry] {
        perButton.map { ButtonColorLegend.Entry(label: $0.label, colorHex: $0.colorHex) }
    }

    private var maxHourCount: Int { heatmap.map(\.count).max() ?? 0 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Picker("Range", selection: $range) {
                    ForEach(StatsRange.allCases) { range in Text(range.title).tag(range) }
                }
                .pickerStyle(.segmented)

                if snapshots.isEmpty {
                    ContentUnavailableView {
                        Label("No presses in this range", systemImage: "chart.bar")
                    } description: {
                        Text("Log a press for \(animal.name), or pick a longer range.")
                    }
                    .padding(.top, 40)
                } else {
                    perButtonChart
                    perDayChart
                    heatmapChart
                    sequenceTable
                    repeatTable
                }
            }
            .padding()
        }
    }

    // Chart 1: horizontal bars, one per button, stacked spontaneous then prompted.
    // One value axis and one category axis, never two value axes.
    private var perButtonChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Presses per button").font(.headline)
            Chart {
                ForEach(perButton) { row in
                    BarMark(x: .value("Presses", row.spontaneous),
                            y: .value("Button", row.label))
                        .foregroundStyle(ColorPalette.color(row.colorHex))
                    BarMark(x: .value("Presses", row.prompted),
                            y: .value("Button", row.label))
                        .foregroundStyle(ColorPalette.color(row.colorHex))
                        .opacity(0.5)
                }
            }
            .chartXAxisLabel("Presses")
            .chartYAxis { AxisMarks(preset: .aligned, position: .leading) }
            .frame(height: CGFloat(perButton.count) * 40 + 40)
            PressKindLegend()
            ButtonColorLegend(entries: legendEntries)
        }
    }

    // Chart 2: one bar per day, stacked by button, colored by the button's own hex.
    private var perDayChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Presses per day").font(.headline)
            Chart(perDay) { row in
                BarMark(x: .value("Day", row.day, unit: .day),
                        y: .value("Presses", row.count))
                    .foregroundStyle(by: .value("Button", row.label))
            }
            .chartForegroundStyleScale(domain: legendEntries.map(\.label),
                                       range: legendEntries.map { ColorPalette.color($0.colorHex) })
            .chartYAxisLabel("Presses")
            .chartLegend(position: .bottom, alignment: .leading)
            .frame(height: 240)
        }
    }

    // Chart 3: hour of day by button. One rectangle per hour that has presses, darker for more.
    private var heatmapChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Time of day").font(.headline)
            Chart(heatmap) { cell in
                RectangleMark(xStart: .value("Hour", Double(cell.hour)),
                              xEnd: .value("Hour end", Double(cell.hour + 1)),
                              y: .value("Button", cell.label))
                    .foregroundStyle(ColorPalette.color(cell.colorHex))
                    .opacity(intensity(cell.count))
            }
            .chartXScale(domain: 0.0...24.0)
            .chartXAxis {
                AxisMarks(values: [0.0, 6.0, 12.0, 18.0, 24.0]) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel {
                        if let hour = value.as(Double.self) { Text(hourLabel(Int(hour))) }
                    }
                }
            }
            .chartYAxis { AxisMarks(preset: .aligned, position: .leading) }
            .frame(height: CGFloat(heatmapRowCount) * 40 + 40)
            HeatmapIntensityLegend()
            ButtonColorLegend(entries: legendEntries)
        }
    }

    private var heatmapRowCount: Int { Set(heatmap.map(\.label)).count }

    private func intensity(_ count: Int) -> Double {
        guard maxHourCount > 0 else { return 0.15 }
        return 0.15 + 0.85 * (Double(count) / Double(maxHourCount))
    }

    private func hourLabel(_ hour: Int) -> String {
        switch hour {
        case 0, 24: return "12a"
        case 12: return "12p"
        case let h where h < 12: return "\(h)a"
        default: return "\(hour - 12)p"
        }
    }

    private var sequenceTable: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sequences").font(.headline)
            let rows = StatsAggregator.sequenceCounts(sequences)
            if rows.isEmpty {
                Text("No runs of two or more different buttons in this range.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rows) { row in
                    HStack {
                        Text(row.labels.joined(separator: " \u{2192} "))
                        Spacer(minLength: 8)
                        Text("\(row.count)").monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                    Divider()
                }
            }
        }
    }

    private var repeatTable: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Repeats").font(.headline)
            let rows = StatsAggregator.repeatCounts(sequences)
            if rows.isEmpty {
                Text("No runs of the same button pressed twice or more in this range.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rows) { row in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(ColorPalette.color(row.colorHex))
                            .frame(width: 10, height: 10)
                        Text(row.label)
                        Spacer(minLength: 8)
                        Text("\(row.count)").monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                    Divider()
                }
            }
        }
    }
}
```

- [ ] **Step 6: Run to verify pass**

Run: `scripts/test-app.sh`
Expected: `Executed 52 tests, with 0 failures`.

- [ ] **Step 7: Look at the app**

Run: `scripts/run-sim.sh`. Log several presses of both buttons, some prompted, some in quick runs of Out then Treat. Open Stats and read `build/screenshot.png`. Check each item:
- The range picker reads 7 days, 30 days, All, and starts on 7 days.
- Chart 1 draws one horizontal bar per button in that button's color, each split into a solid and a half-opacity part, with one value axis along the bottom and the button names on the left. Two legends sit below it.
- Chart 2 draws one bar per day stacked by button, with its own legend at the bottom and the same color per button as chart 1.
- Chart 3 draws hour-wide rectangles, darker where more presses fall, with the hour labels 12a, 6a, 12p, 6p, 12a along the bottom.
- The Sequences table lists "Out → Treat" with a count, and the Repeats table lists any button pressed twice in a row.
- Switch the range to All and confirm the charts redraw. Switch the animal to one with no presses and confirm the empty state replaces all five blocks.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat(buttons): Stats section with per-button, per-day, and hourly charts plus sequence and repeat tables

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Self-review

Run after the last task, and fixed inline above.

**Spec coverage.** Data model / Buttons domain: Task 1, both models field for field against the contract, deny delete rule, presses relationship. Settings: `sequenceWindowSeconds` and `defaultPressKind` are read in Tasks 5, 6, and 7 and written in Task 4's Manage section. Buttons tab segmented control and the Manage-first rule for an animal with no buttons: Task 4. Log, one tap, kind toggle that resets, three-second toast with Undo, long-press note sheet with the 60-second rule, archived empty state: Task 5. History, day sections, sequences with arrows and a disclosure, swipe delete, tap to edit timestamp, kind, and note: Task 6. Stats, range picker, three charts, sequence table, repeat counts, empty state: Task 7. Logic: `Sequencer.group` in Task 2, the five `StatsAggregator` functions in Task 3, `PressSnapshot` in Task 1. Error handling: every save is wrapped and surfaces an alert without presenting the change as saved, and deleting a button with presses is blocked with an explanation to archive instead. Testing: every file under `Logic/` has an XCTest file written before the implementation. Out of this plan's scope by the spec: export of `presses.csv` and the JSON keys `buttons` and `presses` belong to Plan G, which reads these models.

**Placeholder scan.** No task says "similar to", "TBD", or "add validation". The three stub views created in Task 4 are full compiling files and each is replaced by a named later task with its complete replacement code. Every code step carries the whole file or the whole replaced declaration.

**Type consistency.** `PressSnapshot` fields match the model contract exactly and are used with the same names in `Sequencer`, `StatsAggregator`, `HistoryGrouping`, `StatsRange`, and the views. `PressSequence` exposes `presses`, `labels`, `buttonIDs`, `start`, `end`, `isSingle`, and is the single sequence type across Tasks 2, 3, 6, and 7. `StatsAggregator` row types are referenced as `StatsAggregator.ButtonCount` and friends in Task 7 with the same property names defined in Task 3. `AACButton.pressCount` and `AACButton.canDelete` are defined in Task 1 and used in Task 4. `ButtonsSection.initial(hasButtons:)` is defined and called in Task 4 and tested with that signature. `ButtonLogView(animal:)`, `ButtonHistoryView(animal:)`, `ButtonStatsView(animal:)`, and `ManageButtonsView(animal:)` keep the same single unlabeled-by-name `animal` parameter from the stubs through their replacements. `ColorPalette.color(_:)`, `ColorPalette.hex(_:)`, `ColorPalette.contrastingText(on:)`, `ColorPalette.presets`, and `ColorPalette.defaultHex` are used exactly as Plan A defines them.
