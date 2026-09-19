# AnimalTracker Plan E: Poop and Health Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Poop and Health subsystems: two SwiftData domains, a one-time built-in poop tag seed, the two-tap poop quick-add tab, a Manage Poop Tags screen in Settings, and a camera-first health check-in tab with a full-screen media detail.

**Architecture:** Models follow the shared model contract exactly. All rules that can be expressed over values (tag ordering, tag deletability, day grouping, check-in validity) live in `App/Logic/` with no SwiftData imports and are unit-tested without a container. Everything that touches the store or the media store goes through two thin store enums, `PoopStore`/`PoopTagStore` and `HealthStore`, which are tested against an in-memory container and `InMemoryMediaStore`. The views are thin: they read the animal from `@Environment(\.selectedAnimal)`, never create their own `NavigationStack` (Plan A's `RootTabView` supplies one with the shared toolbar), and hand every mutation to a store.

**Tech Stack:** Swift 5 language mode, iOS 17, SwiftUI, SwiftData, PhotosUI, AVKit, XCTest. No third-party packages, no iCloud.

**Spec:** `docs/superpowers/specs/2026-09-16-animal-tracker-design.md` (sections: Constraints, Top-level navigation, Data model/Poop domain + Health domain, Settings, Poop tab, Health tab, Logic, Error handling, Testing) and the binding names in `docs/superpowers/specs/2026-09-18-model-contract.md`. Builds on `docs/superpowers/plans/2026-09-18-animal-tracker-A-foundation.md` (assume every Plan A task is implemented).

## Global Constraints

- iOS deployment target `17.0`; Swift 5 language mode (`SWIFT_VERSION = 5.0`); never Swift 6 strict concurrency.
- SwiftUI, SwiftData, PhotosUI and AVKit only. No third-party packages, no iCloud, no entitlements.
- Test target `AnimalTrackerTests`, sources in `AppTests/`, every test file uses `@testable import AnimalTracker`. Run with `scripts/test-app.sh`.
- In-memory SwiftData in tests comes from `TestSupport.container()`. Media in tests comes from `InMemoryMediaStore`. Pure logic tests must not touch SwiftData.
- Visual checks run `scripts/run-sim.sh` and read `build/screenshot.png`.
- Every model has `var id: UUID = UUID()` and `var createdAt: Date = Date()`; every stored property has a default or is optional; relationships are optional; enums are stored as String raw values.
- Media filenames are relative to `Documents/Media/` and only ever go through `MediaStore`. Videos are capped at 60 seconds.
- Media write failures surface as an alert and nothing is saved. Missing files on disk show a placeholder.
- Logging a normal poop must be two taps. A Health check-in must reach the camera in one tap.
- Tab root views do not create a `NavigationStack`; they read `@Environment(\.selectedAnimal)` and show an empty state when it is nil.
- Commit after every task with the message shown; do not push. Every commit message ends with the trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.

## Assumptions

Decisions the spec left open, and how this plan resolves them:

1. **Built-in tag colors.** The spec names 14 built-in poop tags but `ColorPalette.presets` has 12 colors. Task 2 assigns colors from the palette in a fixed order; two colors repeat (`#2A78D6` for "undigested food" and "large volume", `#6B7280` for "dry" and "none today"). Exact hexes are pinned in the seed and asserted in a test.
2. **Seed guard.** `hasSeededPoopTags` is read and written through a `UserDefaults` instance passed into `PoopTagSeed.seed(context:defaults:)`, so tests can use a throwaway suite. `PoopTagSeed.run(context:)`, the closure registered in `Seeds.all`, passes `.standard`, which is the same storage `@AppStorage("hasSeededPoopTags")` reads.
3. **Tag chip ordering.** Ties in `sortOrder` are broken by lowercased name, so the order is deterministic.
4. **Relationship array order.** SwiftData to-many arrays are unordered, so an observation's tags are always rendered sorted by tag `sortOrder` then name (`PoopObservation.orderedTagNames`).
5. **Day section headers.** "Today", "Yesterday", otherwise an abbreviated weekday, month, day and year.
6. **Hidden tags while editing.** A hidden tag already attached to an observation still shows as a chip in the editor, so editing cannot silently drop it.
7. **Duplicate tag names** are rejected case-insensitively, both when adding and when renaming.
8. **Tag colors are set at creation.** Renaming and hiding are available for every tag; recoloring an existing tag is out of scope, and built-ins keep their seeded colors.
9. **Reordering tags** reassigns `sortOrder` 0..n-1 over all tags, hidden ones included.
10. **Camera mode switch.** Plan A's `CameraCaptureView` takes a single mode, so the photo/video switch is a segmented `Picker` above it in `HealthCameraContainer`, which recreates the picker with `.id(mode)`. The video branch passes `maxVideoSeconds: 60`.
11. **Library videos** arrive as a `PickedMovie` `Transferable` copied into the temporary directory, then copied into the media store by `MediaStore.saveVideo(from:)`.
12. **Note-only and From library** sit in a row directly under the large Check in button, so Check in stays a single tap to the camera.
13. **Timestamps.** New records use the save time. `editedAt` is nil at creation and set on every later edit.
14. **Deletion policy keys** are exactly `"poop observations"` and `"health check-ins"`, so `AnimalDeletionPolicy.summary` renders "3 poop observations, 1 health check-ins".
15. **Confirmation.** Deleting a poop observation is a swipe with no confirmation (the spec says swipe to delete); deleting a health check-in asks for confirmation (the spec says so) because it also destroys media files.
16. **A check-in with both photo and video** shows the photo in the detail view; Add photo and Add video only appear for the media that is missing.

## File Structure

```
App/Models/PoopTag.swift                        PoopTag model (global across animals)
App/Models/PoopObservation.swift                PoopObservation model, orderedTagNames
App/Models/HealthCheckIn.swift                  HealthCheckIn model, hasMedia
App/Persistence/PoopTagSeed.swift               the 14 built-ins, guarded one-time seed
App/Persistence/PoopStore.swift                 insert/update/delete observations
App/Persistence/PoopTagStore.swift              add/rename/reorder/delete tags with reasons
App/Persistence/HealthStore.swift               create/attach/update/delete check-ins and their media
App/Logic/DayGrouping.swift                     DaySection, DayGrouping, RecordListing (pure)
App/Logic/PoopTagRules.swift                    PoopTagInfo + ordering, naming, deletability (pure)
App/Logic/HealthCheckInValidation.swift         at-least-one-of rule + note chips (pure)
App/Logic/Snapshots.swift                       MODIFY: add PoopSnapshot and HealthSnapshot
App/Persistence/AnimalDeletionPolicy.swift      MODIFY: two record-count entries
App/Persistence/PersistenceController.swift     MODIFY: three model types
App/AnimalTrackerApp.swift                      MODIFY: register PoopTagSeed.run in Seeds.all
App/RootTabView.swift                           MODIFY: Poop and Health tab contents
App/Views/Settings/SettingsView.swift           MODIFY: Poop tags row becomes a NavigationLink
App/Views/Poop/PoopTagChip.swift                one tag pill, filled or outlined
App/Views/Poop/PoopTabView.swift                quick-add bar + observations grouped by day
App/Views/Poop/PoopObservationEditView.swift    edit timestamp, tags, note
App/Views/Poop/ManagePoopTagsView.swift         rename, hide, add, delete, reorder
App/Views/Health/HealthLibraryLoader.swift      PickedMovie Transferable + PhotosPicker loader
App/Views/Health/HealthCaptureSheet.swift       media preview, note chips, Save
App/Views/Health/HealthCameraContainer.swift    photo/video switch over CameraCaptureView
App/Views/Health/HealthMediaThumbnail.swift     thumbnail, video badge, note icon, placeholder
App/Views/Health/HealthTabView.swift            Check in button + check-ins grouped by day
App/Views/Health/HealthCheckInDetailView.swift  zoom photo, play video, edit, add media, delete
AppTests/PoopModelTests.swift                   5 tests
AppTests/PoopTagSeedTests.swift                 4 tests
AppTests/DayGroupingTests.swift                 4 tests
AppTests/PoopTagRulesTests.swift                4 tests
AppTests/PoopStoreTests.swift                   4 tests
AppTests/PoopTagStoreTests.swift                5 tests
AppTests/HealthModelTests.swift                 6 tests
AppTests/HealthStoreTests.swift                 4 tests
AppTests/HealthListingTests.swift               2 tests
AppTests/HealthDetailStoreTests.swift           5 tests
```

Plan A ends with 19 passing tests. This plan adds 43, for 62 if no other plan has run.

---

### Task 1: Poop models, PoopSnapshot, registration, deletion policy

**Files:**
- Create: `App/Models/PoopTag.swift`, `App/Models/PoopObservation.swift`
- Modify: `App/Logic/Snapshots.swift` (append `PoopSnapshot`), `App/Persistence/PersistenceController.swift` (`modelTypes`), `App/Persistence/AnimalDeletionPolicy.swift` (`recordCounts`)
- Test: `AppTests/PoopModelTests.swift`

**Interfaces:**
- Consumes: `Animal`, `ColorPalette.defaultHex`, `PersistenceController.makeContainer(inMemory:)`, `AnimalDeletionPolicy.recordCounts(for:context:)`, `TestSupport.container()`.
- Produces: `PoopTag(name:colorHex:isBuiltIn:isHidden:sortOrder:)` with `id, createdAt, name, colorHex, isBuiltIn, isHidden, sortOrder, observations`; `PoopObservation(timestamp:tags:note:animal:)` with `id, createdAt, timestamp, tags, note, editedAt, animal` and `var orderedTagNames: [String]`; `PoopSnapshot(id:timestamp:tagNames:note:)` plus `init(_ observation: PoopObservation)`; the `"poop observations"` key in `AnimalDeletionPolicy.recordCounts`.

**Adds 5 tests.**

- [ ] **Step 1: Write the failing tests**

`AppTests/PoopModelTests.swift`:
```swift
import SwiftData
import XCTest
@testable import AnimalTracker

@MainActor
final class PoopModelTests: XCTestCase {
    func testObservationRoundTripWithTags() throws {
        let context = try TestSupport.container().mainContext
        let animal = Animal(name: "Juniper", species: "horse")
        let normal = PoopTag(name: "normal", colorHex: "#1BAF7A", isBuiltIn: true, sortOrder: 0)
        let soft = PoopTag(name: "soft", colorHex: "#EDA100", isBuiltIn: true, sortOrder: 1)
        context.insert(animal)
        context.insert(normal)
        context.insert(soft)
        let when = Date(timeIntervalSince1970: 1_750_000_000)
        context.insert(PoopObservation(timestamp: when, tags: [soft, normal], note: "by the gate", animal: animal))
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<PoopObservation>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].timestamp, when)
        XCTAssertEqual(fetched[0].note, "by the gate")
        XCTAssertNil(fetched[0].editedAt)
        XCTAssertEqual(fetched[0].animal?.id, animal.id)
        XCTAssertEqual(fetched[0].orderedTagNames, ["normal", "soft"])
    }

    func testTagDefaultsAndInverse() throws {
        let context = try TestSupport.container().mainContext
        let tag = PoopTag(name: "mucus")
        context.insert(tag)
        try context.save()
        XCTAssertEqual(tag.colorHex, ColorPalette.defaultHex)
        XCTAssertFalse(tag.isBuiltIn)
        XCTAssertFalse(tag.isHidden)
        XCTAssertEqual(tag.sortOrder, 0)
        XCTAssertEqual(tag.observations?.count ?? 0, 0)

        let animal = Animal(name: "Juniper", species: "horse")
        context.insert(animal)
        context.insert(PoopObservation(tags: [tag], animal: animal))
        try context.save()
        XCTAssertEqual(tag.observations?.count, 1)
    }

    func testOneTagIsSharedByManyObservations() throws {
        let context = try TestSupport.container().mainContext
        let animal = Animal(name: "Juniper", species: "horse")
        let tag = PoopTag(name: "normal", sortOrder: 0)
        context.insert(animal)
        context.insert(tag)
        context.insert(PoopObservation(timestamp: Date(), tags: [tag], animal: animal))
        context.insert(PoopObservation(timestamp: Date().addingTimeInterval(60), tags: [tag], animal: animal))
        try context.save()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PoopTag>()), 1)
        XCTAssertEqual(tag.observations?.count, 2)
    }

    func testDeletingAnObservationKeepsItsTags() throws {
        let context = try TestSupport.container().mainContext
        let animal = Animal(name: "Juniper", species: "horse")
        let tag = PoopTag(name: "normal", sortOrder: 0)
        context.insert(animal)
        context.insert(tag)
        let observation = PoopObservation(tags: [tag], animal: animal)
        context.insert(observation)
        try context.save()
        context.delete(observation)
        try context.save()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PoopObservation>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PoopTag>()), 1)
    }

    func testSnapshotAndDeletionPolicy() throws {
        let context = try TestSupport.container().mainContext
        let animal = Animal(name: "Juniper", species: "horse")
        let tag = PoopTag(name: "runny", sortOrder: 3)
        context.insert(animal)
        context.insert(tag)
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let observation = PoopObservation(timestamp: when, tags: [tag], note: "watery", animal: animal)
        context.insert(observation)
        try context.save()

        let snapshot = PoopSnapshot(observation)
        XCTAssertEqual(snapshot.id, observation.id)
        XCTAssertEqual(snapshot.timestamp, when)
        XCTAssertEqual(snapshot.tagNames, ["runny"])
        XCTAssertEqual(snapshot.note, "watery")

        let counts = try AnimalDeletionPolicy.recordCounts(for: animal, context: context)
        XCTAssertEqual(counts["poop observations"], 1)
        XCTAssertFalse(try AnimalDeletionPolicy.canDelete(animal, context: context))
        XCTAssertTrue(AnimalDeletionPolicy.summary(counts).contains("1 poop observations"))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test-app.sh`
Expected: build errors, `PoopTag`, `PoopObservation` and `PoopSnapshot` not found.

- [ ] **Step 3: Write the models**

`App/Models/PoopTag.swift`:
```swift
import Foundation
import SwiftData

/// A poop descriptor, global across animals. Built-ins can be hidden and renamed but never deleted.
@Model
final class PoopTag {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var name: String = ""
    var colorHex: String = ColorPalette.defaultHex
    var isBuiltIn: Bool = false
    var isHidden: Bool = false
    var sortOrder: Int = 0
    @Relationship(inverse: \PoopObservation.tags) var observations: [PoopObservation]?

    init(name: String,
         colorHex: String = ColorPalette.defaultHex,
         isBuiltIn: Bool = false,
         isHidden: Bool = false,
         sortOrder: Int = 0) {
        self.name = name
        self.colorHex = colorHex
        self.isBuiltIn = isBuiltIn
        self.isHidden = isHidden
        self.sortOrder = sortOrder
    }
}
```

`App/Models/PoopObservation.swift`:
```swift
import Foundation
import SwiftData

/// One poop, tagged with any number of PoopTags.
@Model
final class PoopObservation {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var timestamp: Date = Date()
    var tags: [PoopTag]?
    var note: String?
    var editedAt: Date?
    var animal: Animal?

    init(timestamp: Date = Date(), tags: [PoopTag] = [], note: String? = nil, animal: Animal? = nil) {
        self.timestamp = timestamp
        self.tags = tags
        self.note = note
        self.animal = animal
    }

    /// SwiftData to-many arrays are unordered, so display and export always sort here.
    var orderedTagNames: [String] {
        (tags ?? [])
            .sorted { ($0.sortOrder, $0.name.lowercased()) < ($1.sortOrder, $1.name.lowercased()) }
            .map(\.name)
    }
}
```

- [ ] **Step 4: Add the snapshot**

Append to `App/Logic/Snapshots.swift` (keep `AnimalSnapshot` and anything other plans added):
```swift
struct PoopSnapshot: Equatable, Identifiable {
    let id: UUID
    let timestamp: Date
    let tagNames: [String]
    let note: String?

    init(id: UUID, timestamp: Date, tagNames: [String], note: String?) {
        self.id = id
        self.timestamp = timestamp
        self.tagNames = tagNames
        self.note = note
    }

    init(_ observation: PoopObservation) {
        self.init(id: observation.id,
                  timestamp: observation.timestamp,
                  tagNames: observation.orderedTagNames,
                  note: observation.note)
    }
}
```

- [ ] **Step 5: Register the models**

In `App/Persistence/PersistenceController.swift`, add two lines to `modelTypes`, keeping every entry that is already there:
```swift
    static let modelTypes: [any PersistentModel.Type] = [
        Animal.self,
        PoopTag.self,
        PoopObservation.self,
    ]
```

- [ ] **Step 6: Add the deletion-policy entry**

In `App/Persistence/AnimalDeletionPolicy.swift`, replace the body of `recordCounts` with the following, keeping any entries other plans already added and deleting Plan A's `_ = animal` and `_ = context` lines:
```swift
    static func recordCounts(for animal: Animal, context: ModelContext) throws -> [String: Int] {
        var counts: [String: Int] = [:]
        let animalID = animal.id
        counts["poop observations"] = try context.fetchCount(
            FetchDescriptor<PoopObservation>(predicate: #Predicate { $0.animal?.id == animalID })
        )
        return counts
    }
```

- [ ] **Step 7: Run to verify pass**

Run: `scripts/test-app.sh`
Expected: the 5 new `PoopModelTests` pass and every earlier test still passes.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat(poop): PoopTag and PoopObservation models, PoopSnapshot, deletion policy entry

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: One-time built-in poop tag seed

**Files:**
- Create: `App/Persistence/PoopTagSeed.swift`
- Modify: `App/AnimalTrackerApp.swift` (`Seeds.all`)
- Test: `AppTests/PoopTagSeedTests.swift`

**Interfaces:**
- Consumes: `PoopTag`, `TestSupport.container()`, `Seeds.all: [(ModelContext) -> Void]`.
- Produces: `PoopTagSeed.seedGuardKey = "hasSeededPoopTags"`, `PoopTagSeed.builtIns: [(name: String, colorHex: String)]` (14 entries in spec order), `PoopTagSeed.run(context: ModelContext)`, `@discardableResult PoopTagSeed.seed(context: ModelContext, defaults: UserDefaults) -> Int` returning how many tags it inserted.

**Adds 4 tests.**

- [ ] **Step 1: Write the failing tests**

`AppTests/PoopTagSeedTests.swift`:
```swift
import SwiftData
import XCTest
@testable import AnimalTracker

@MainActor
final class PoopTagSeedTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "poop-seed-\(UUID().uuidString)")!
    }

    func testSeedsFourteenBuiltInsInSpecOrder() throws {
        let context = try TestSupport.container().mainContext
        XCTAssertEqual(PoopTagSeed.seed(context: context, defaults: freshDefaults()), 14)
        let tags = try context.fetch(FetchDescriptor<PoopTag>(sortBy: [SortDescriptor(\.sortOrder)]))
        XCTAssertEqual(tags.map(\.name), [
            "normal", "soft", "loose", "runny", "hard", "dry", "mucus",
            "blood", "green", "undigested food", "foul smell",
            "small volume", "large volume", "none today",
        ])
        XCTAssertEqual(tags.map(\.sortOrder), Array(0..<14))
        XCTAssertTrue(tags.allSatisfy(\.isBuiltIn))
        XCTAssertTrue(tags.allSatisfy { !$0.isHidden })
    }

    func testGuardStopsASecondRun() throws {
        let context = try TestSupport.container().mainContext
        let defaults = freshDefaults()
        XCTAssertEqual(PoopTagSeed.seed(context: context, defaults: defaults), 14)
        XCTAssertTrue(defaults.bool(forKey: PoopTagSeed.seedGuardKey))
        XCTAssertEqual(PoopTagSeed.seed(context: context, defaults: defaults), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PoopTag>()), 14)
    }

    func testSkipsNamesAlreadyPresentCaseInsensitively() throws {
        let context = try TestSupport.container().mainContext
        context.insert(PoopTag(name: "Normal", colorHex: "#111827", sortOrder: 0))
        context.insert(PoopTag(name: "none today", colorHex: "#111827", sortOrder: 1))
        try context.save()
        XCTAssertEqual(PoopTagSeed.seed(context: context, defaults: freshDefaults()), 12)
        let names = try context.fetch(FetchDescriptor<PoopTag>()).map { $0.name.lowercased() }.sorted()
        XCTAssertEqual(names.count, 14)
        XCTAssertEqual(names.filter { $0 == "normal" }.count, 1)
        XCTAssertEqual(names.filter { $0 == "none today" }.count, 1)
    }

    func testGuardKeyAndColorsComeFromThePalette() {
        XCTAssertEqual(PoopTagSeed.seedGuardKey, "hasSeededPoopTags")
        XCTAssertEqual(PoopTagSeed.builtIns.count, 14)
        XCTAssertTrue(PoopTagSeed.builtIns.allSatisfy { ColorPalette.presets.contains($0.colorHex) })
        XCTAssertEqual(PoopTagSeed.builtIns.first?.colorHex, "#1BAF7A")
        XCTAssertEqual(PoopTagSeed.builtIns.last?.colorHex, "#6B7280")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test-app.sh`
Expected: build error, `PoopTagSeed` not found.

- [ ] **Step 3: Implement the seed**

`App/Persistence/PoopTagSeed.swift`:
```swift
import Foundation
import SwiftData

/// The 14 built-in poop tags from the design spec, inserted once on first launch.
/// Two palette colors repeat because ColorPalette has 12 presets and the spec names 14 tags.
enum PoopTagSeed {
    static let seedGuardKey = "hasSeededPoopTags"

    static let builtIns: [(name: String, colorHex: String)] = [
        ("normal", "#1BAF7A"),
        ("soft", "#EDA100"),
        ("loose", "#EB6834"),
        ("runny", "#E87BA4"),
        ("hard", "#8B5A2B"),
        ("dry", "#6B7280"),
        ("mucus", "#00A3B4"),
        ("blood", "#E34948"),
        ("green", "#008300"),
        ("undigested food", "#2A78D6"),
        ("foul smell", "#4A3AA7"),
        ("small volume", "#111827"),
        ("large volume", "#2A78D6"),
        ("none today", "#6B7280"),
    ]

    /// The closure registered in Seeds.all. Uses the same storage @AppStorage reads.
    static func run(context: ModelContext) {
        seed(context: context, defaults: .standard)
    }

    /// Inserts the built-ins that are missing, once. Returns how many were inserted.
    @discardableResult
    static func seed(context: ModelContext, defaults: UserDefaults) -> Int {
        if defaults.bool(forKey: seedGuardKey) { return 0 }
        let existing = (try? context.fetch(FetchDescriptor<PoopTag>())) ?? []
        var present = Set(existing.map { $0.name.lowercased() })
        var order = (existing.map(\.sortOrder).max() ?? -1) + 1
        var inserted = 0
        for builtIn in builtIns where !present.contains(builtIn.name.lowercased()) {
            context.insert(PoopTag(name: builtIn.name,
                                   colorHex: builtIn.colorHex,
                                   isBuiltIn: true,
                                   sortOrder: order))
            present.insert(builtIn.name.lowercased())
            order += 1
            inserted += 1
        }
        if inserted > 0 { try? context.save() }
        defaults.set(true, forKey: seedGuardKey)
        return inserted
    }
}
```

- [ ] **Step 4: Register the seed**

In `App/AnimalTrackerApp.swift`, add `PoopTagSeed.run` to `Seeds.all`, keeping any seeds other plans registered:
```swift
enum Seeds {
    static let all: [(ModelContext) -> Void] = [
        PoopTagSeed.run,
    ]

    static func runAll(context: ModelContext) {
        for seed in all { seed(context) }
    }
}
```

- [ ] **Step 5: Run to verify pass**

Run: `scripts/test-app.sh`
Expected: the 4 new `PoopTagSeedTests` pass and every earlier test still passes.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(poop): seed the 14 built-in poop tags once, guarded by hasSeededPoopTags

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: Pure logic: day grouping, record listing, poop tag rules

**Files:**
- Create: `App/Logic/DayGrouping.swift`, `App/Logic/PoopTagRules.swift`
- Test: `AppTests/DayGroupingTests.swift`, `AppTests/PoopTagRulesTests.swift`

**Interfaces:**
- Consumes: `PoopSnapshot`, `ColorPalette.defaultHex`, `PoopTag` (for the `PoopTagInfo(_:)` convenience only).
- Produces: `struct DaySection<Item>: Identifiable { let id: Date; let items: [Item]; var day: Date }`; `DayGrouping.sections<Item>(_:calendar:timestamp:) -> [DaySection<Item>]`; `DayGrouping.title(for:now:calendar:) -> String`; `RecordListing.sections<Item>(_:animalID:calendar:animal:timestamp:) -> [DaySection<Item>]`; `struct PoopTagInfo: Equatable, Identifiable` with `id, name, colorHex, isBuiltIn, isHidden, sortOrder`, `init(id:name:colorHex:isBuiltIn:isHidden:sortOrder:)` and `init(_ tag: PoopTag)`; `PoopTagRules.quickAddTags(_:) -> [PoopTagInfo]`, `PoopTagRules.canDelete(isBuiltIn:observationCount:) -> Bool`, `PoopTagRules.nextSortOrder(_:) -> Int`, `PoopTagRules.normalizedName(_:) -> String`, `PoopTagRules.isDuplicateName(_:in:excluding:) -> Bool`.

**Adds 8 tests** (4 + 4). Neither test file imports SwiftData.

- [ ] **Step 1: Write the failing tests**

`AppTests/DayGroupingTests.swift`:
```swift
import XCTest
@testable import AnimalTracker

final class DayGroupingTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()

    private func date(_ iso: String) -> Date {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: iso)!
    }

    private func snap(_ iso: String, _ tag: String) -> PoopSnapshot {
        PoopSnapshot(id: UUID(), timestamp: date(iso), tagNames: [tag], note: nil)
    }

    func testGroupsByDayNewestFirstAndNewestRecordFirst() {
        let items = [snap("2026-09-16 08:00", "a"),
                     snap("2026-09-18 07:00", "b"),
                     snap("2026-09-18 19:30", "c"),
                     snap("2026-09-17 23:59", "d")]
        let sections = DayGrouping.sections(items, calendar: calendar) { $0.timestamp }
        XCTAssertEqual(sections.count, 3)
        XCTAssertEqual(sections.map(\.day), [date("2026-09-18 00:00"), date("2026-09-17 00:00"), date("2026-09-16 00:00")])
        XCTAssertEqual(sections[0].items.map { $0.tagNames[0] }, ["c", "b"])
        XCTAssertEqual(sections[0].id, sections[0].day)
    }

    func testEmptyInputMakesNoSections() {
        XCTAssertTrue(DayGrouping.sections([PoopSnapshot](), calendar: calendar) { $0.timestamp }.isEmpty)
    }

    func testTitleUsesTodayAndYesterday() {
        let now = date("2026-09-18 12:00")
        XCTAssertEqual(DayGrouping.title(for: date("2026-09-18 00:00"), now: now, calendar: calendar), "Today")
        XCTAssertEqual(DayGrouping.title(for: date("2026-09-17 00:00"), now: now, calendar: calendar), "Yesterday")
        let older = DayGrouping.title(for: date("2026-09-11 00:00"), now: now, calendar: calendar)
        XCTAssertNotEqual(older, "Today")
        XCTAssertNotEqual(older, "Yesterday")
        XCTAssertTrue(older.contains("11"))
    }

    func testRecordListingFiltersByAnimal() {
        let mine = UUID(), theirs = UUID()
        let items: [(animal: UUID, at: Date)] = [
            (mine, date("2026-09-18 08:00")),
            (theirs, date("2026-09-18 09:00")),
            (mine, date("2026-09-17 08:00")),
        ]
        let sections = RecordListing.sections(items, animalID: mine, calendar: calendar,
                                              animal: { $0.animal }, timestamp: { $0.at })
        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(sections.flatMap(\.items).count, 2)
        XCTAssertTrue(sections.flatMap(\.items).allSatisfy { $0.animal == mine })
    }
}
```

`AppTests/PoopTagRulesTests.swift`:
```swift
import XCTest
@testable import AnimalTracker

final class PoopTagRulesTests: XCTestCase {
    private func info(_ name: String, order: Int, hidden: Bool = false, builtIn: Bool = true) -> PoopTagInfo {
        PoopTagInfo(id: UUID(), name: name, colorHex: "#2A78D6", isBuiltIn: builtIn, isHidden: hidden, sortOrder: order)
    }

    func testQuickAddTagsDropHiddenAndSortBySortOrderThenName() {
        let tags = [info("soft", order: 2),
                    info("blood", order: 0),
                    info("hidden one", order: 1, hidden: true),
                    info("Apple", order: 2)]
        XCTAssertEqual(PoopTagRules.quickAddTags(tags).map(\.name), ["blood", "Apple", "soft"])
    }

    func testCanDeleteOnlyUnusedCustomTags() {
        XCTAssertTrue(PoopTagRules.canDelete(isBuiltIn: false, observationCount: 0))
        XCTAssertFalse(PoopTagRules.canDelete(isBuiltIn: false, observationCount: 1))
        XCTAssertFalse(PoopTagRules.canDelete(isBuiltIn: true, observationCount: 0))
        XCTAssertFalse(PoopTagRules.canDelete(isBuiltIn: true, observationCount: 3))
    }

    func testNextSortOrderAndNormalizedName() {
        XCTAssertEqual(PoopTagRules.nextSortOrder([]), 0)
        XCTAssertEqual(PoopTagRules.nextSortOrder([info("a", order: 0), info("b", order: 7)]), 8)
        XCTAssertEqual(PoopTagRules.normalizedName("  extra  wet \n"), "extra  wet")
        XCTAssertEqual(PoopTagRules.normalizedName("   "), "")
    }

    func testDuplicateNamesAreCaseInsensitiveAndIgnoreTheTagBeingRenamed() {
        let soft = info("soft", order: 1)
        let tags = [info("normal", order: 0), soft]
        XCTAssertTrue(PoopTagRules.isDuplicateName("SOFT", in: tags))
        XCTAssertTrue(PoopTagRules.isDuplicateName(" normal ", in: tags))
        XCTAssertFalse(PoopTagRules.isDuplicateName("Soft", in: tags, excluding: soft.id))
        XCTAssertFalse(PoopTagRules.isDuplicateName("sticky", in: tags))
        XCTAssertFalse(PoopTagRules.isDuplicateName("   ", in: tags))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test-app.sh`
Expected: build errors, `DayGrouping`, `RecordListing`, `PoopTagInfo` and `PoopTagRules` not found.

- [ ] **Step 3: Implement the grouping**

`App/Logic/DayGrouping.swift`:
```swift
import Foundation

/// One calendar day of records. `id` is the local start of that day.
struct DaySection<Item>: Identifiable {
    let id: Date
    let items: [Item]

    var day: Date { id }
}

enum DayGrouping {
    /// Newest day first, newest record first inside each day.
    static func sections<Item>(_ items: [Item],
                               calendar: Calendar = .current,
                               timestamp: (Item) -> Date) -> [DaySection<Item>] {
        var buckets: [Date: [Item]] = [:]
        for item in items {
            buckets[calendar.startOfDay(for: timestamp(item)), default: []].append(item)
        }
        return buckets.keys.sorted(by: >).map { day in
            DaySection(id: day, items: (buckets[day] ?? []).sorted { timestamp($0) > timestamp($1) })
        }
    }

    /// "Today", "Yesterday", otherwise an abbreviated date.
    static func title(for day: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)),
           calendar.isDate(day, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        return day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year())
    }
}

enum RecordListing {
    /// One animal's records, grouped into day sections.
    static func sections<Item>(_ items: [Item],
                               animalID: UUID,
                               calendar: Calendar = .current,
                               animal: (Item) -> UUID?,
                               timestamp: (Item) -> Date) -> [DaySection<Item>] {
        DayGrouping.sections(items.filter { animal($0) == animalID }, calendar: calendar, timestamp: timestamp)
    }
}
```

- [ ] **Step 4: Implement the tag rules**

`App/Logic/PoopTagRules.swift`:
```swift
import Foundation

/// Value copy of a PoopTag so ordering and naming rules are testable without a container.
struct PoopTagInfo: Equatable, Identifiable {
    let id: UUID
    let name: String
    let colorHex: String
    let isBuiltIn: Bool
    let isHidden: Bool
    let sortOrder: Int

    init(id: UUID = UUID(),
         name: String,
         colorHex: String = ColorPalette.defaultHex,
         isBuiltIn: Bool = false,
         isHidden: Bool = false,
         sortOrder: Int = 0) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.isBuiltIn = isBuiltIn
        self.isHidden = isHidden
        self.sortOrder = sortOrder
    }

    init(_ tag: PoopTag) {
        self.init(id: tag.id, name: tag.name, colorHex: tag.colorHex,
                  isBuiltIn: tag.isBuiltIn, isHidden: tag.isHidden, sortOrder: tag.sortOrder)
    }
}

enum PoopTagRules {
    /// Chips for the quick-add bar: not hidden, in sortOrder then name.
    static func quickAddTags(_ tags: [PoopTagInfo]) -> [PoopTagInfo] {
        tags.filter { !$0.isHidden }
            .sorted { ($0.sortOrder, $0.name.lowercased()) < ($1.sortOrder, $1.name.lowercased()) }
    }

    /// Built-ins are never deletable; custom tags only while no observation uses them.
    static func canDelete(isBuiltIn: Bool, observationCount: Int) -> Bool {
        !isBuiltIn && observationCount == 0
    }

    static func nextSortOrder(_ tags: [PoopTagInfo]) -> Int {
        (tags.map(\.sortOrder).max() ?? -1) + 1
    }

    static func normalizedName(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Case-insensitive, ignoring the tag being renamed. A blank name is not a duplicate; it is rejected elsewhere.
    static func isDuplicateName(_ raw: String, in tags: [PoopTagInfo], excluding id: UUID? = nil) -> Bool {
        let name = normalizedName(raw).lowercased()
        guard !name.isEmpty else { return false }
        return tags.contains { $0.id != id && $0.name.lowercased() == name }
    }
}
```

- [ ] **Step 5: Run to verify pass**

Run: `scripts/test-app.sh`
Expected: the 8 new tests pass and every earlier test still passes.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(logic): day grouping, per-animal record listing, poop tag ordering and naming rules

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: Poop tab: quick-add bar, day-grouped list, edit sheet, tab wiring

**Files:**
- Create: `App/Persistence/PoopStore.swift`, `App/Views/Poop/PoopTagChip.swift`, `App/Views/Poop/PoopTabView.swift`, `App/Views/Poop/PoopObservationEditView.swift`
- Modify: `App/RootTabView.swift` (the Poop tab line)
- Test: `AppTests/PoopStoreTests.swift`

**Interfaces:**
- Consumes: `PoopTag`, `PoopObservation`, `PoopTagInfo`, `PoopTagRules.quickAddTags(_:)`, `RecordListing.sections(_:animalID:calendar:animal:timestamp:)`, `DayGrouping.title(for:now:calendar:)`, `ColorPalette`, `@Environment(\.selectedAnimal)`, `TestSupport.container()`.
- Produces: `PoopStore.add(tags:note:animal:at:context:) throws -> PoopObservation`, `PoopStore.update(_:timestamp:tags:note:now:context:) throws`, `PoopStore.delete(_:context:) throws`; `PoopTagChip(name:colorHex:isSelected:)`; `PoopTabView()`; `PoopObservationEditView(observation:)`.

**Adds 4 tests.**

- [ ] **Step 1: Write the failing tests**

`AppTests/PoopStoreTests.swift`:
```swift
import SwiftData
import XCTest
@testable import AnimalTracker

@MainActor
final class PoopStoreTests: XCTestCase {
    private func fixture() throws -> (ModelContext, Animal, PoopTag, PoopTag) {
        let context = try TestSupport.container().mainContext
        let animal = Animal(name: "Juniper", species: "horse")
        let normal = PoopTag(name: "normal", colorHex: "#1BAF7A", isBuiltIn: true, sortOrder: 0)
        let soft = PoopTag(name: "soft", colorHex: "#EDA100", isBuiltIn: true, sortOrder: 1)
        context.insert(animal)
        context.insert(normal)
        context.insert(soft)
        try context.save()
        return (context, animal, normal, soft)
    }

    func testAddInsertsForTheAnimalAtTheGivenTime() throws {
        let (context, animal, normal, _) = try fixture()
        let when = Date(timeIntervalSince1970: 1_760_000_000)
        let observation = try PoopStore.add(tags: [normal], note: "  by the gate  ", animal: animal, at: when, context: context)
        XCTAssertEqual(observation.timestamp, when)
        XCTAssertEqual(observation.animal?.id, animal.id)
        XCTAssertEqual(observation.orderedTagNames, ["normal"])
        XCTAssertEqual(observation.note, "by the gate")
        XCTAssertNil(observation.editedAt)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PoopObservation>()), 1)
    }

    func testBlankNoteBecomesNil() throws {
        let (context, animal, normal, _) = try fixture()
        let observation = try PoopStore.add(tags: [normal], note: "   ", animal: animal, at: Date(), context: context)
        XCTAssertNil(observation.note)
    }

    func testUpdateReplacesTagsAndStampsEditedAt() throws {
        let (context, animal, normal, soft) = try fixture()
        let observation = try PoopStore.add(tags: [normal], note: "", animal: animal, at: Date(), context: context)
        let later = Date(timeIntervalSince1970: 1_770_000_000)
        try PoopStore.update(observation, timestamp: later, tags: [soft], note: "runnier", now: later, context: context)
        XCTAssertEqual(observation.timestamp, later)
        XCTAssertEqual(observation.orderedTagNames, ["soft"])
        XCTAssertEqual(observation.note, "runnier")
        XCTAssertEqual(observation.editedAt, later)
    }

    func testDeleteRemovesTheObservationOnly() throws {
        let (context, animal, normal, _) = try fixture()
        let observation = try PoopStore.add(tags: [normal], note: "", animal: animal, at: Date(), context: context)
        try PoopStore.delete(observation, context: context)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PoopObservation>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PoopTag>()), 2)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test-app.sh`
Expected: build error, `PoopStore` not found.

- [ ] **Step 3: Implement the store**

`App/Persistence/PoopStore.swift`:
```swift
import Foundation
import SwiftData

/// Every poop write goes through here so the views stay thin and the rules stay tested.
enum PoopStore {
    @discardableResult
    static func add(tags: [PoopTag], note: String, animal: Animal, at timestamp: Date, context: ModelContext) throws -> PoopObservation {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let observation = PoopObservation(timestamp: timestamp,
                                          tags: tags,
                                          note: trimmed.isEmpty ? nil : trimmed,
                                          animal: animal)
        context.insert(observation)
        do {
            try context.save()
        } catch {
            context.delete(observation)
            throw error
        }
        return observation
    }

    static func update(_ observation: PoopObservation, timestamp: Date, tags: [PoopTag], note: String, now: Date, context: ModelContext) throws {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        observation.timestamp = timestamp
        observation.tags = tags
        observation.note = trimmed.isEmpty ? nil : trimmed
        observation.editedAt = now
        try context.save()
    }

    static func delete(_ observation: PoopObservation, context: ModelContext) throws {
        context.delete(observation)
        try context.save()
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `scripts/test-app.sh`
Expected: the 4 new `PoopStoreTests` pass.

- [ ] **Step 5: Write the chip**

`App/Views/Poop/PoopTagChip.swift`:
```swift
import SwiftUI

/// A tag pill in the tag's own color: filled when selected, outlined when not.
struct PoopTagChip: View {
    let name: String
    let colorHex: String
    var isSelected: Bool = true

    var body: some View {
        Text(name)
            .font(.subheadline.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                isSelected ? ColorPalette.color(colorHex) : ColorPalette.color(colorHex).opacity(0.14),
                in: Capsule()
            )
            .foregroundStyle(isSelected ? ColorPalette.contrastingText(on: colorHex) : ColorPalette.color(colorHex))
            .overlay(Capsule().stroke(ColorPalette.color(colorHex), lineWidth: isSelected ? 0 : 1))
    }
}
```

- [ ] **Step 6: Write the tab**

`App/Views/Poop/PoopTabView.swift`:
```swift
import SwiftData
import SwiftUI

/// Quick-add bar on top, observations grouped by day below.
/// No NavigationStack here: RootTabView supplies one with the shared toolbar.
struct PoopTabView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.selectedAnimal) private var animal
    @Query(sort: \PoopTag.sortOrder) private var allTags: [PoopTag]
    @Query(sort: \PoopObservation.timestamp, order: .reverse) private var allObservations: [PoopObservation]

    @State private var selectedTagIDs: Set<UUID> = []
    @State private var note = ""
    @State private var editing: PoopObservation?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let animal {
                list(for: animal)
            } else {
                ContentUnavailableView("No animal selected",
                                       systemImage: "pawprint",
                                       description: Text("Add or select an animal to log poop."))
            }
        }
        .sheet(item: $editing) { observation in
            NavigationStack { PoopObservationEditView(observation: observation) }
        }
        .alert("Could not save",
               isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var chips: [PoopTagInfo] { PoopTagRules.quickAddTags(allTags.map(PoopTagInfo.init)) }

    private func sections(for animal: Animal) -> [DaySection<PoopObservation>] {
        RecordListing.sections(allObservations,
                               animalID: animal.id,
                               animal: { $0.animal?.id },
                               timestamp: { $0.timestamp })
    }

    private func list(for animal: Animal) -> some View {
        List {
            Section("Log a poop") { quickAdd(for: animal) }
            let sections = sections(for: animal)
            if sections.isEmpty {
                Section {
                    Text("No observations yet for \(animal.name).")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(sections) { section in
                Section(DayGrouping.title(for: section.day)) {
                    ForEach(section.items) { observation in
                        Button { editing = observation } label: { row(observation) }
                            .swipeActions(edge: .trailing) {
                                Button("Delete", role: .destructive) { delete(observation) }
                            }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func quickAdd(for animal: Animal) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if chips.isEmpty {
                Text("Every tag is hidden. Add or unhide tags in Settings.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(chips) { tag in
                        Button {
                            toggle(tag.id)
                        } label: {
                            PoopTagChip(name: tag.name, colorHex: tag.colorHex, isSelected: selectedTagIDs.contains(tag.id))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selectedTagIDs.contains(tag.id) ? .isSelected : [])
                    }
                }
                .padding(.vertical, 2)
            }
            TextField("Note (optional)", text: $note, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
            Button {
                save(for: animal)
            } label: {
                Label("Save", systemImage: "plus.circle.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(selectedTagIDs.isEmpty)
        }
        .padding(.vertical, 4)
    }

    private func row(_ observation: PoopObservation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(observation.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 68, alignment: .leading)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(orderedTags(observation)) { tag in
                            PoopTagChip(name: tag.name, colorHex: tag.colorHex)
                        }
                    }
                }
            }
            if let note = observation.note, !note.isEmpty {
                Text(note).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .foregroundStyle(.primary)
    }

    private func orderedTags(_ observation: PoopObservation) -> [PoopTagInfo] {
        (observation.tags ?? [])
            .map(PoopTagInfo.init)
            .sorted { ($0.sortOrder, $0.name.lowercased()) < ($1.sortOrder, $1.name.lowercased()) }
    }

    private func toggle(_ id: UUID) {
        if selectedTagIDs.contains(id) { selectedTagIDs.remove(id) } else { selectedTagIDs.insert(id) }
    }

    private func save(for animal: Animal) {
        let tags = allTags.filter { selectedTagIDs.contains($0.id) }
        do {
            try PoopStore.add(tags: tags, note: note, animal: animal, at: Date(), context: context)
            selectedTagIDs.removeAll()
            note = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ observation: PoopObservation) {
        do { try PoopStore.delete(observation, context: context) }
        catch { errorMessage = error.localizedDescription }
    }
}
```

- [ ] **Step 7: Write the edit sheet**

`App/Views/Poop/PoopObservationEditView.swift`:
```swift
import SwiftData
import SwiftUI

/// Edit an observation's time, tags and note. Saving stamps editedAt.
struct PoopObservationEditView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \PoopTag.sortOrder) private var allTags: [PoopTag]

    let observation: PoopObservation

    @State private var timestamp = Date()
    @State private var selectedTagIDs: Set<UUID> = []
    @State private var note = ""
    @State private var errorMessage: String?

    /// Hidden tags still show when this observation already carries them.
    private var chips: [PoopTagInfo] {
        let attached = Set((observation.tags ?? []).map(\.id))
        return allTags.map(PoopTagInfo.init)
            .filter { !$0.isHidden || attached.contains($0.id) }
            .sorted { ($0.sortOrder, $0.name.lowercased()) < ($1.sortOrder, $1.name.lowercased()) }
    }

    var body: some View {
        Form {
            Section("Time") {
                DatePicker("Time", selection: $timestamp)
                    .datePickerStyle(.compact)
            }
            Section("Tags") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(chips) { tag in
                        Button {
                            if selectedTagIDs.contains(tag.id) { selectedTagIDs.remove(tag.id) } else { selectedTagIDs.insert(tag.id) }
                        } label: {
                            PoopTagChip(name: tag.name, colorHex: tag.colorHex, isSelected: selectedTagIDs.contains(tag.id))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selectedTagIDs.contains(tag.id) ? .isSelected : [])
                    }
                }
            }
            Section("Note") {
                TextField("Note", text: $note, axis: .vertical).lineLimit(2...6)
            }
            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Edit observation")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save).disabled(selectedTagIDs.isEmpty)
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
        .onAppear {
            timestamp = observation.timestamp
            selectedTagIDs = Set((observation.tags ?? []).map(\.id))
            note = observation.note ?? ""
        }
    }

    private func save() {
        let tags = allTags.filter { selectedTagIDs.contains($0.id) }
        do {
            try PoopStore.update(observation, timestamp: timestamp, tags: tags, note: note, now: Date(), context: context)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
```

- [ ] **Step 8: Wire the tab**

In `App/RootTabView.swift`, replace this line:
```swift
            tab("Poop", "circle.dotted") { Text("Poop") }
```
with:
```swift
            tab("Poop", "circle.dotted") { PoopTabView() }
```

- [ ] **Step 9: Build, run, look**

Run: `scripts/test-app.sh` (all tests pass), then `scripts/run-sim.sh`.
Read `build/screenshot.png`. Add an animal in the simulator, open the Poop tab, and confirm: the quick-add bar shows the 14 seeded chips in tag colors, Save is greyed out until a chip is tapped, tapping "normal" then Save adds a row under "Today" with the time and a filled "normal" chip, and the chip selection clears. Swipe a row to see Delete; tap a row to open the edit sheet.

- [ ] **Step 10: Commit**

```bash
git add -A
git commit -m "feat(poop): quick-add bar, day-grouped observations, edit sheet, Poop tab wiring

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: Manage Poop Tags screen in Settings

**Files:**
- Create: `App/Persistence/PoopTagStore.swift`, `App/Views/Poop/ManagePoopTagsView.swift`
- Modify: `App/Views/Settings/SettingsView.swift` (the Poop tags row)
- Test: `AppTests/PoopTagStoreTests.swift`

**Interfaces:**
- Consumes: `PoopTag`, `PoopObservation`, `PoopTagInfo`, `PoopTagRules`, `ColorPalette.presets`, `TestSupport.container()`.
- Produces: `PoopTagStoreError` (`.builtIn(String)`, `.inUse(String, Int)`, `.duplicateName(String)`) conforming to `LocalizedError`; `PoopTagStore.observationCount(for:) -> Int`, `PoopTagStore.add(name:colorHex:existing:context:) throws -> PoopTag`, `PoopTagStore.rename(_:to:existing:context:) throws`, `PoopTagStore.setHidden(_:_:context:) throws`, `PoopTagStore.reorder(_:context:) throws`, `PoopTagStore.delete(_:context:) throws`; `ManagePoopTagsView()`.

**Adds 5 tests.**

- [ ] **Step 1: Write the failing tests**

`AppTests/PoopTagStoreTests.swift`:
```swift
import SwiftData
import XCTest
@testable import AnimalTracker

@MainActor
final class PoopTagStoreTests: XCTestCase {
    private func tags(_ context: ModelContext) throws -> [PoopTag] {
        try context.fetch(FetchDescriptor<PoopTag>(sortBy: [SortDescriptor(\.sortOrder)]))
    }

    func testAddAppendsACustomTagAtTheEnd() throws {
        let context = try TestSupport.container().mainContext
        context.insert(PoopTag(name: "normal", isBuiltIn: true, sortOrder: 0))
        try context.save()
        let added = try PoopTagStore.add(name: "  sandy  ", colorHex: ColorPalette.presets[3], existing: try tags(context), context: context)
        XCTAssertEqual(added.name, "sandy")
        XCTAssertFalse(added.isBuiltIn)
        XCTAssertEqual(added.sortOrder, 1)
        XCTAssertEqual(added.colorHex, ColorPalette.presets[3])
    }

    func testAddRejectsBlankAndDuplicateNames() throws {
        let context = try TestSupport.container().mainContext
        context.insert(PoopTag(name: "normal", isBuiltIn: true, sortOrder: 0))
        try context.save()
        XCTAssertThrowsError(try PoopTagStore.add(name: "  ", colorHex: ColorPalette.presets[0], existing: try tags(context), context: context))
        XCTAssertThrowsError(try PoopTagStore.add(name: "NORMAL", colorHex: ColorPalette.presets[0], existing: try tags(context), context: context))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PoopTag>()), 1)
    }

    func testRenameAndHideWorkForBuiltIns() throws {
        let context = try TestSupport.container().mainContext
        let builtIn = PoopTag(name: "normal", isBuiltIn: true, sortOrder: 0)
        context.insert(builtIn)
        try context.save()
        try PoopTagStore.rename(builtIn, to: "  regular ", existing: try tags(context), context: context)
        XCTAssertEqual(builtIn.name, "regular")
        try PoopTagStore.setHidden(builtIn, true, context: context)
        XCTAssertTrue(builtIn.isHidden)
        XCTAssertThrowsError(try PoopTagStore.rename(builtIn, to: "", existing: try tags(context), context: context))
    }

    func testDeleteRefusesBuiltInsAndUsedCustomTags() throws {
        let context = try TestSupport.container().mainContext
        let animal = Animal(name: "Juniper", species: "horse")
        let builtIn = PoopTag(name: "normal", isBuiltIn: true, sortOrder: 0)
        let custom = PoopTag(name: "sandy", sortOrder: 1)
        context.insert(animal)
        context.insert(builtIn)
        context.insert(custom)
        context.insert(PoopObservation(tags: [custom], animal: animal))
        try context.save()

        XCTAssertEqual(PoopTagStore.observationCount(for: custom), 1)
        XCTAssertThrowsError(try PoopTagStore.delete(builtIn, context: context))
        XCTAssertThrowsError(try PoopTagStore.delete(custom, context: context)) { error in
            XCTAssertTrue((error as? PoopTagStoreError)?.errorDescription?.contains("sandy") ?? false)
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PoopTag>()), 2)
    }

    func testDeleteUnusedCustomTagAndReorder() throws {
        let context = try TestSupport.container().mainContext
        let a = PoopTag(name: "a", isBuiltIn: true, sortOrder: 0)
        let b = PoopTag(name: "b", isBuiltIn: true, sortOrder: 1)
        let custom = PoopTag(name: "sandy", sortOrder: 2)
        context.insert(a)
        context.insert(b)
        context.insert(custom)
        try context.save()

        try PoopTagStore.delete(custom, context: context)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PoopTag>()), 2)

        try PoopTagStore.reorder([b, a], context: context)
        XCTAssertEqual(try tags(context).map(\.name), ["b", "a"])
        XCTAssertEqual(try tags(context).map(\.sortOrder), [0, 1])
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test-app.sh`
Expected: build error, `PoopTagStore` not found.

- [ ] **Step 3: Implement the store**

`App/Persistence/PoopTagStore.swift`:
```swift
import Foundation
import SwiftData

enum PoopTagStoreError: LocalizedError {
    case builtIn(String)
    case inUse(String, Int)
    case duplicateName(String)

    var errorDescription: String? {
        switch self {
        case .builtIn(let name):
            return "\"\(name)\" is a built-in tag. Hide it instead of deleting it."
        case .inUse(let name, let count):
            return "\"\(name)\" is used by \(count) observation\(count == 1 ? "" : "s"). Hide it instead of deleting it."
        case .duplicateName(let name):
            return name.isEmpty ? "Give the tag a name." : "There is already a tag called \"\(name)\"."
        }
    }
}

/// Tag management, with the reasons a tag cannot be deleted spelled out.
enum PoopTagStore {
    /// The inverse relationship, so no predicate over a to-many is needed.
    static func observationCount(for tag: PoopTag) -> Int {
        tag.observations?.count ?? 0
    }

    @discardableResult
    static func add(name: String, colorHex: String, existing: [PoopTag], context: ModelContext) throws -> PoopTag {
        let trimmed = PoopTagRules.normalizedName(name)
        let infos = existing.map(PoopTagInfo.init)
        guard !trimmed.isEmpty, !PoopTagRules.isDuplicateName(trimmed, in: infos) else {
            throw PoopTagStoreError.duplicateName(trimmed)
        }
        let tag = PoopTag(name: trimmed, colorHex: colorHex, isBuiltIn: false, sortOrder: PoopTagRules.nextSortOrder(infos))
        context.insert(tag)
        do {
            try context.save()
        } catch {
            context.delete(tag)
            throw error
        }
        return tag
    }

    static func rename(_ tag: PoopTag, to name: String, existing: [PoopTag], context: ModelContext) throws {
        let trimmed = PoopTagRules.normalizedName(name)
        let infos = existing.map(PoopTagInfo.init)
        guard !trimmed.isEmpty, !PoopTagRules.isDuplicateName(trimmed, in: infos, excluding: tag.id) else {
            throw PoopTagStoreError.duplicateName(trimmed)
        }
        tag.name = trimmed
        try context.save()
    }

    static func setHidden(_ tag: PoopTag, _ hidden: Bool, context: ModelContext) throws {
        tag.isHidden = hidden
        try context.save()
    }

    static func reorder(_ ordered: [PoopTag], context: ModelContext) throws {
        for (index, tag) in ordered.enumerated() { tag.sortOrder = index }
        try context.save()
    }

    static func delete(_ tag: PoopTag, context: ModelContext) throws {
        let count = observationCount(for: tag)
        guard PoopTagRules.canDelete(isBuiltIn: tag.isBuiltIn, observationCount: count) else {
            throw tag.isBuiltIn ? PoopTagStoreError.builtIn(tag.name) : PoopTagStoreError.inUse(tag.name, count)
        }
        context.delete(tag)
        try context.save()
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `scripts/test-app.sh`
Expected: the 5 new `PoopTagStoreTests` pass.

- [ ] **Step 5: Write the screen**

`App/Views/Poop/ManagePoopTagsView.swift`:
```swift
import SwiftData
import SwiftUI

/// Rename and hide built-ins, add custom tags with a palette color, delete unused custom tags, reorder.
struct ManagePoopTagsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \PoopTag.sortOrder) private var tags: [PoopTag]

    @State private var newName = ""
    @State private var newColorHex = ColorPalette.presets[0]
    @State private var renaming: PoopTag?
    @State private var renameText = ""
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section("Add a tag") {
                TextField("Tag name", text: $newName)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 10) {
                    ForEach(ColorPalette.presets, id: \.self) { hex in
                        Circle()
                            .fill(ColorPalette.color(hex))
                            .frame(width: 32, height: 32)
                            .overlay(Circle().stroke(Color.primary, lineWidth: newColorHex == hex ? 3 : 0))
                            .onTapGesture { newColorHex = hex }
                            .accessibilityLabel(hex)
                    }
                }
                Button("Add tag") { add() }
                    .disabled(PoopTagRules.normalizedName(newName).isEmpty)
            }
            Section {
                ForEach(tags) { tag in
                    row(tag)
                        .swipeActions(edge: .trailing) {
                            Button("Delete", role: .destructive) { delete(tag) }
                        }
                }
                .onMove(perform: move)
            } header: {
                Text("Tags")
            } footer: {
                Text("Built-in tags can be renamed and hidden but not deleted. Custom tags can be deleted only while no observation uses them.")
            }
        }
        .navigationTitle("Poop tags")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { EditButton() } }
        .sheet(item: $renaming) { tag in
            NavigationStack {
                Form {
                    TextField("Name", text: $renameText)
                }
                .navigationTitle("Rename tag")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { rename(tag) }
                            .disabled(PoopTagRules.normalizedName(renameText).isEmpty)
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { renaming = nil }
                    }
                }
            }
        }
        .alert("Cannot do that",
               isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func row(_ tag: PoopTag) -> some View {
        HStack(spacing: 12) {
            Circle().fill(ColorPalette.color(tag.colorHex)).frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(tag.name)
                Text(tag.isBuiltIn ? "Built-in" : "Custom")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                renameText = tag.name
                renaming = tag
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Rename \(tag.name)")
            Toggle("Show \(tag.name)", isOn: Binding(
                get: { !tag.isHidden },
                set: { shown in setHidden(tag, !shown) }
            ))
            .labelsHidden()
        }
    }

    private func add() {
        do {
            try PoopTagStore.add(name: newName, colorHex: newColorHex, existing: tags, context: context)
            newName = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func rename(_ tag: PoopTag) {
        do {
            try PoopTagStore.rename(tag, to: renameText, existing: tags, context: context)
            renaming = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func setHidden(_ tag: PoopTag, _ hidden: Bool) {
        do { try PoopTagStore.setHidden(tag, hidden, context: context) }
        catch { errorMessage = error.localizedDescription }
    }

    private func delete(_ tag: PoopTag) {
        do { try PoopTagStore.delete(tag, context: context) }
        catch { errorMessage = error.localizedDescription }
    }

    private func move(from source: IndexSet, to destination: Int) {
        var ordered = tags
        ordered.move(fromOffsets: source, toOffset: destination)
        do { try PoopTagStore.reorder(ordered, context: context) }
        catch { errorMessage = error.localizedDescription }
    }
}
```

- [ ] **Step 6: Link it from Settings**

In `App/Views/Settings/SettingsView.swift`, replace this line:
```swift
                SettingsPlaceholderRow(title: "Poop tags")
```
with:
```swift
                NavigationLink("Poop tags") { ManagePoopTagsView() }
```
Leave `SettingsPlaceholderRow(title: "Voice tags")` and the `SettingsPlaceholderRow` type alone; other plans still use them.

- [ ] **Step 7: Build, run, look**

Run: `scripts/test-app.sh` (all tests pass), then `scripts/run-sim.sh`.
Read `build/screenshot.png`. Open the gear icon, tap "Poop tags", and confirm: 14 rows with colored swatches, each with a rename pencil and a show/hide toggle; Edit reorders; typing a name and picking a color adds a custom tag at the bottom; swiping Delete on a built-in shows "is a built-in tag. Hide it instead."; hiding a tag removes its chip from the Poop tab.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat(poop): Manage Poop Tags screen with rename, hide, add, reorder and guarded delete

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: HealthCheckIn model, validation rule, note chips, registration

**Files:**
- Create: `App/Models/HealthCheckIn.swift`, `App/Logic/HealthCheckInValidation.swift`
- Modify: `App/Logic/Snapshots.swift` (append `HealthSnapshot`), `App/Persistence/PersistenceController.swift` (`modelTypes`), `App/Persistence/AnimalDeletionPolicy.swift` (`recordCounts`)
- Test: `AppTests/HealthModelTests.swift`

**Interfaces:**
- Consumes: `Animal`, `AnimalDeletionPolicy.recordCounts(for:context:)`, `TestSupport.container()`.
- Produces: `HealthCheckIn(timestamp:photoFilename:thumbnailFilename:videoFilename:note:animal:)` with `id, createdAt, timestamp, photoFilename, thumbnailFilename, videoFilename, note, editedAt, animal` and `var hasMedia: Bool`; `HealthSnapshot(id:timestamp:photoFilename:videoFilename:note:)` plus `init(_ checkIn: HealthCheckIn)`; `HealthCheckInValidation.isValid(photoFilename:videoFilename:note:) -> Bool` and `HealthCheckInValidation.invalidMessage: String`; `HealthNotePresets.chips: [String]` (9 entries in spec order); the `"health check-ins"` key in `AnimalDeletionPolicy.recordCounts`.

**Adds 6 tests.** The three validation tests live in a file that does not import SwiftData.

- [ ] **Step 1: Write the failing tests**

`AppTests/HealthModelTests.swift`:
```swift
import SwiftData
import XCTest
@testable import AnimalTracker

final class HealthCheckInValidationTests: XCTestCase {
    func testAnyOnePieceOfContentIsEnough() {
        XCTAssertTrue(HealthCheckInValidation.isValid(photoFilename: "a-photo.jpg", videoFilename: nil, note: nil))
        XCTAssertTrue(HealthCheckInValidation.isValid(photoFilename: nil, videoFilename: "a-video.mov", note: nil))
        XCTAssertTrue(HealthCheckInValidation.isValid(photoFilename: nil, videoFilename: nil, note: "limping"))
        XCTAssertTrue(HealthCheckInValidation.isValid(photoFilename: "a-photo.jpg", videoFilename: "a-video.mov", note: "both"))
    }

    func testNothingOrBlankNoteIsInvalid() {
        XCTAssertFalse(HealthCheckInValidation.isValid(photoFilename: nil, videoFilename: nil, note: nil))
        XCTAssertFalse(HealthCheckInValidation.isValid(photoFilename: nil, videoFilename: nil, note: ""))
        XCTAssertFalse(HealthCheckInValidation.isValid(photoFilename: nil, videoFilename: nil, note: "   \n "))
        XCTAssertFalse(HealthCheckInValidation.isValid(photoFilename: "", videoFilename: "", note: " "))
    }

    func testNoteChipsMatchTheSpec() {
        XCTAssertEqual(HealthNotePresets.chips, [
            "acting normally", "lying down more", "off food", "lethargic",
            "limping", "vomiting", "coughing", "scratching", "other",
        ])
        XCTAssertFalse(HealthCheckInValidation.invalidMessage.isEmpty)
    }
}

@MainActor
final class HealthModelTests: XCTestCase {
    func testRoundTripAndDefaults() throws {
        let context = try TestSupport.container().mainContext
        let animal = Animal(name: "Juniper", species: "horse")
        context.insert(animal)
        let when = Date(timeIntervalSince1970: 1_750_000_000)
        let checkIn = HealthCheckIn(timestamp: when, note: "off food", animal: animal)
        context.insert(checkIn)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<HealthCheckIn>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].timestamp, when)
        XCTAssertEqual(fetched[0].note, "off food")
        XCTAssertNil(fetched[0].photoFilename)
        XCTAssertNil(fetched[0].thumbnailFilename)
        XCTAssertNil(fetched[0].videoFilename)
        XCTAssertNil(fetched[0].editedAt)
        XCTAssertFalse(fetched[0].hasMedia)
        XCTAssertEqual(fetched[0].animal?.id, animal.id)
    }

    func testHasMediaAndSnapshot() throws {
        let context = try TestSupport.container().mainContext
        let animal = Animal(name: "Juniper", species: "horse")
        context.insert(animal)
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let checkIn = HealthCheckIn(timestamp: when,
                                    photoFilename: "abc-photo.jpg",
                                    thumbnailFilename: "abc-thumb.jpg",
                                    note: "swelling",
                                    animal: animal)
        context.insert(checkIn)
        try context.save()

        XCTAssertTrue(checkIn.hasMedia)
        let snapshot = HealthSnapshot(checkIn)
        XCTAssertEqual(snapshot.id, checkIn.id)
        XCTAssertEqual(snapshot.timestamp, when)
        XCTAssertEqual(snapshot.photoFilename, "abc-photo.jpg")
        XCTAssertNil(snapshot.videoFilename)
        XCTAssertEqual(snapshot.note, "swelling")
    }

    func testDeletionPolicyCountsCheckIns() throws {
        let context = try TestSupport.container().mainContext
        let animal = Animal(name: "Juniper", species: "horse")
        let other = Animal(name: "Rex", species: "dog")
        context.insert(animal)
        context.insert(other)
        context.insert(HealthCheckIn(note: "fine", animal: animal))
        context.insert(HealthCheckIn(note: "fine", animal: animal))
        try context.save()

        let counts = try AnimalDeletionPolicy.recordCounts(for: animal, context: context)
        XCTAssertEqual(counts["health check-ins"], 2)
        XCTAssertFalse(try AnimalDeletionPolicy.canDelete(animal, context: context))
        XCTAssertEqual(try AnimalDeletionPolicy.recordCounts(for: other, context: context)["health check-ins"], 0)
        XCTAssertTrue(try AnimalDeletionPolicy.canDelete(other, context: context))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test-app.sh`
Expected: build errors, `HealthCheckIn`, `HealthSnapshot`, `HealthCheckInValidation` and `HealthNotePresets` not found.

- [ ] **Step 3: Write the model**

`App/Models/HealthCheckIn.swift`:
```swift
import Foundation
import SwiftData

/// One wellbeing check-in: a photo, a video, a note, or any combination. Filenames are relative to Documents/Media/.
@Model
final class HealthCheckIn {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var timestamp: Date = Date()
    var photoFilename: String?
    var thumbnailFilename: String?
    var videoFilename: String?
    var note: String?
    var editedAt: Date?
    var animal: Animal?

    init(timestamp: Date = Date(),
         photoFilename: String? = nil,
         thumbnailFilename: String? = nil,
         videoFilename: String? = nil,
         note: String? = nil,
         animal: Animal? = nil) {
        self.timestamp = timestamp
        self.photoFilename = photoFilename
        self.thumbnailFilename = thumbnailFilename
        self.videoFilename = videoFilename
        self.note = note
        self.animal = animal
    }

    var hasMedia: Bool { photoFilename != nil || videoFilename != nil }
}
```

- [ ] **Step 4: Write the validation rule**

`App/Logic/HealthCheckInValidation.swift`:
```swift
import Foundation

/// A check-in needs at least one of photo, video, or a non-blank note (spec, Health domain).
enum HealthCheckInValidation {
    static let invalidMessage = "Add a photo, a video, or a note before saving."

    static func isValid(photoFilename: String?, videoFilename: String?, note: String?) -> Bool {
        if let photoFilename, !photoFilename.isEmpty { return true }
        if let videoFilename, !videoFilename.isEmpty { return true }
        return !(note ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Quick-insert chips for the note field, in the spec's order.
enum HealthNotePresets {
    static let chips = [
        "acting normally", "lying down more", "off food", "lethargic",
        "limping", "vomiting", "coughing", "scratching", "other",
    ]
}
```

- [ ] **Step 5: Add the snapshot**

Append to `App/Logic/Snapshots.swift`:
```swift
struct HealthSnapshot: Equatable, Identifiable {
    let id: UUID
    let timestamp: Date
    let photoFilename: String?
    let videoFilename: String?
    let note: String?

    init(id: UUID, timestamp: Date, photoFilename: String?, videoFilename: String?, note: String?) {
        self.id = id
        self.timestamp = timestamp
        self.photoFilename = photoFilename
        self.videoFilename = videoFilename
        self.note = note
    }

    init(_ checkIn: HealthCheckIn) {
        self.init(id: checkIn.id,
                  timestamp: checkIn.timestamp,
                  photoFilename: checkIn.photoFilename,
                  videoFilename: checkIn.videoFilename,
                  note: checkIn.note)
    }
}
```

- [ ] **Step 6: Register the model and the record count**

In `App/Persistence/PersistenceController.swift`, add `HealthCheckIn.self` to `modelTypes`:
```swift
    static let modelTypes: [any PersistentModel.Type] = [
        Animal.self,
        PoopTag.self,
        PoopObservation.self,
        HealthCheckIn.self,
    ]
```

In `App/Persistence/AnimalDeletionPolicy.swift`, add the health count to `recordCounts`:
```swift
    static func recordCounts(for animal: Animal, context: ModelContext) throws -> [String: Int] {
        var counts: [String: Int] = [:]
        let animalID = animal.id
        counts["poop observations"] = try context.fetchCount(
            FetchDescriptor<PoopObservation>(predicate: #Predicate { $0.animal?.id == animalID })
        )
        counts["health check-ins"] = try context.fetchCount(
            FetchDescriptor<HealthCheckIn>(predicate: #Predicate { $0.animal?.id == animalID })
        )
        return counts
    }
```

- [ ] **Step 7: Run to verify pass**

Run: `scripts/test-app.sh`
Expected: the 6 new tests pass and every earlier test still passes.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat(health): HealthCheckIn model, at-least-one-of validation, note chips, deletion policy entry

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: HealthStore create path, library loader, capture sheet, camera container

**Files:**
- Create: `App/Persistence/HealthStore.swift`, `App/Views/Health/HealthLibraryLoader.swift`, `App/Views/Health/HealthCameraContainer.swift`, `App/Views/Health/HealthCaptureSheet.swift`
- Test: `AppTests/HealthStoreTests.swift`

**Interfaces:**
- Consumes: `HealthCheckIn`, `HealthCheckInValidation`, `HealthNotePresets`, `MediaStore` (`savePhoto(_:) -> SavedPhoto`, `saveVideo(from:) -> String`, `url(for:)`, `exists(_:)`, `delete(_:)`), `InMemoryMediaStore`, `CameraCaptureView(mode:maxVideoSeconds:onPhoto:onVideo:)`, `Animal`, `TestSupport.container()`.
- Produces: `enum PendingMedia: Equatable { case none; case photo(Data); case video(URL) }`; `HealthStoreError` (`.nothingToSave`, `.media(String)`) conforming to `LocalizedError`; `HealthStore.create(media:note:animal:at:context:mediaStore:) throws -> HealthCheckIn`; `struct PickedMovie: Transferable`; `HealthLibraryLoader.load(_:) async -> PendingMedia?`; `HealthCameraContainer(onPhoto:onVideo:)`; `HealthCaptureSheet(animal:media:explanation:)`.

**Adds 4 tests.**

- [ ] **Step 1: Write the failing tests**

`AppTests/HealthStoreTests.swift`:
```swift
import SwiftData
import XCTest
@testable import AnimalTracker

/// Every write fails, to prove nothing is saved when media cannot be written.
final class FailingMediaStore: MediaStore {
    func savePhoto(_ data: Data) throws -> SavedPhoto { throw MediaStoreError.writeFailed("disk full") }
    func saveVideo(from url: URL) throws -> String { throw MediaStoreError.writeFailed("disk full") }
    func saveAudio(from url: URL) throws -> String { throw MediaStoreError.writeFailed("disk full") }
    func url(for filename: String) -> URL { URL(fileURLWithPath: "/dev/null") }
    func exists(_ filename: String) -> Bool { false }
    func delete(_ filename: String) {}
}

@MainActor
final class HealthStoreTests: XCTestCase {
    private func fixture() throws -> (ModelContext, Animal) {
        let context = try TestSupport.container().mainContext
        let animal = Animal(name: "Juniper", species: "horse")
        context.insert(animal)
        try context.save()
        return (context, animal)
    }

    func testNoteOnlyCheckIn() throws {
        let (context, animal) = try fixture()
        let when = Date(timeIntervalSince1970: 1_760_000_000)
        let checkIn = try HealthStore.create(media: .none, note: "  off food  ", animal: animal, at: when,
                                             context: context, mediaStore: InMemoryMediaStore())
        XCTAssertEqual(checkIn.note, "off food")
        XCTAssertEqual(checkIn.timestamp, when)
        XCTAssertEqual(checkIn.animal?.id, animal.id)
        XCTAssertFalse(checkIn.hasMedia)
        XCTAssertNil(checkIn.editedAt)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<HealthCheckIn>()), 1)
    }

    func testPhotoCheckInSavesPhotoAndThumbnail() throws {
        let (context, animal) = try fixture()
        let store = InMemoryMediaStore()
        let checkIn = try HealthStore.create(media: .photo(TestImages.jpeg(width: 1200, height: 900)), note: "",
                                             animal: animal, at: Date(), context: context, mediaStore: store)
        let photo = try XCTUnwrap(checkIn.photoFilename)
        let thumb = try XCTUnwrap(checkIn.thumbnailFilename)
        XCTAssertTrue(photo.hasSuffix("-photo.jpg"))
        XCTAssertTrue(thumb.hasSuffix("-thumb.jpg"))
        XCTAssertTrue(store.exists(photo))
        XCTAssertTrue(store.exists(thumb))
        XCTAssertNil(checkIn.note)
        XCTAssertTrue(checkIn.hasMedia)
    }

    func testNothingToSaveWithoutMediaOrNote() throws {
        let (context, animal) = try fixture()
        XCTAssertThrowsError(try HealthStore.create(media: .none, note: "   ", animal: animal, at: Date(),
                                                    context: context, mediaStore: InMemoryMediaStore())) { error in
            XCTAssertEqual((error as? HealthStoreError)?.errorDescription, HealthCheckInValidation.invalidMessage)
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<HealthCheckIn>()), 0)
    }

    func testMediaWriteFailureSavesNothing() throws {
        let (context, animal) = try fixture()
        XCTAssertThrowsError(try HealthStore.create(media: .photo(TestImages.jpeg(width: 100, height: 100)),
                                                    note: "swelling", animal: animal, at: Date(),
                                                    context: context, mediaStore: FailingMediaStore())) { error in
            XCTAssertTrue((error as? HealthStoreError)?.errorDescription?.contains("disk full") ?? false)
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<HealthCheckIn>()), 0)
    }
}
```

`TestImages.jpeg(width:height:)` already exists in `AppTests/ImageProcessingTests.swift` from Plan A Task 4; do not redefine it.

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test-app.sh`
Expected: build errors, `HealthStore`, `HealthStoreError` and `PendingMedia` not found.

- [ ] **Step 3: Implement the store**

`App/Persistence/HealthStore.swift`:
```swift
import Foundation
import SwiftData

/// Media captured or picked but not yet written to the media store.
enum PendingMedia: Equatable {
    case none
    case photo(Data)
    case video(URL)
}

enum HealthStoreError: LocalizedError {
    case nothingToSave
    case media(String)

    var errorDescription: String? {
        switch self {
        case .nothingToSave: return HealthCheckInValidation.invalidMessage
        case .media(let message): return "Could not save the media file: \(message)"
        }
    }
}

/// Every health write goes through here. Media is written first; if that fails, nothing is inserted.
enum HealthStore {
    @discardableResult
    static func create(media: PendingMedia,
                       note: String,
                       animal: Animal,
                       at timestamp: Date,
                       context: ModelContext,
                       mediaStore: MediaStore) throws -> HealthCheckIn {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if media == .none,
           !HealthCheckInValidation.isValid(photoFilename: nil, videoFilename: nil, note: trimmed) {
            throw HealthStoreError.nothingToSave
        }

        var photoFilename: String?
        var thumbnailFilename: String?
        var videoFilename: String?
        switch media {
        case .none:
            break
        case .photo(let data):
            do {
                let saved = try mediaStore.savePhoto(data)
                photoFilename = saved.filename
                thumbnailFilename = saved.thumbnailFilename
            } catch {
                throw HealthStoreError.media(error.localizedDescription)
            }
        case .video(let url):
            do {
                videoFilename = try mediaStore.saveVideo(from: url)
            } catch {
                throw HealthStoreError.media(error.localizedDescription)
            }
        }

        let checkIn = HealthCheckIn(timestamp: timestamp,
                                    photoFilename: photoFilename,
                                    thumbnailFilename: thumbnailFilename,
                                    videoFilename: videoFilename,
                                    note: trimmed.isEmpty ? nil : trimmed,
                                    animal: animal)
        context.insert(checkIn)
        do {
            try context.save()
        } catch {
            context.delete(checkIn)
            for name in [photoFilename, thumbnailFilename, videoFilename].compactMap({ $0 }) {
                mediaStore.delete(name)
            }
            throw error
        }
        return checkIn
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `scripts/test-app.sh`
Expected: the 4 new `HealthStoreTests` pass.

- [ ] **Step 5: Write the library loader**

`App/Views/Health/HealthLibraryLoader.swift`:
```swift
import CoreTransferable
import Foundation
import PhotosUI
import UniformTypeIdentifiers

/// PhotosPicker hands videos over as files, so a Transferable is needed to get a URL.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("picked-\(UUID().uuidString).mov")
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}

enum HealthLibraryLoader {
    /// Video first: a still image never matches the movie type, so this order cannot mis-detect.
    static func load(_ item: PhotosPickerItem) async -> PendingMedia? {
        if let movie = try? await item.loadTransferable(type: PickedMovie.self) {
            return .video(movie.url)
        }
        if let data = try? await item.loadTransferable(type: Data.self) {
            return .photo(data)
        }
        return nil
    }
}
```

- [ ] **Step 6: Write the camera container**

`App/Views/Health/HealthCameraContainer.swift`:
```swift
import SwiftUI

/// CameraCaptureView takes one mode, so the photo/video switch lives here and recreates the picker.
struct HealthCameraContainer: View {
    var onPhoto: (Data) -> Void
    var onVideo: (URL) -> Void

    @State private var mode: CameraCaptureView.Mode = .photo

    var body: some View {
        VStack(spacing: 0) {
            Picker("Capture mode", selection: $mode) {
                Text("Photo").tag(CameraCaptureView.Mode.photo)
                Text("Video").tag(CameraCaptureView.Mode.video)
            }
            .pickerStyle(.segmented)
            .padding(12)
            CameraCaptureView(mode: mode, maxVideoSeconds: 60, onPhoto: onPhoto, onVideo: onVideo)
                .id(mode)
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .ignoresSafeArea(edges: .bottom)
    }
}
```

- [ ] **Step 7: Write the capture sheet**

`App/Views/Health/HealthCaptureSheet.swift`:
```swift
import AVKit
import PhotosUI
import SwiftData
import SwiftUI

/// Shown after a capture, after "Note only", or after a library pick.
struct HealthCaptureSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.mediaStore) private var mediaStore
    @Environment(\.dismiss) private var dismiss

    let animal: Animal
    let explanation: String?
    @State private var media: PendingMedia
    @State private var note = ""
    @State private var libraryItem: PhotosPickerItem?
    @State private var errorMessage: String?

    init(animal: Animal, media: PendingMedia, explanation: String? = nil) {
        self.animal = animal
        self.explanation = explanation
        self._media = State(initialValue: media)
    }

    private var canSave: Bool {
        media != .none || !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                if let explanation {
                    Section {
                        Text(explanation).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("Media") {
                    mediaPreview
                    PhotosPicker("From library", selection: $libraryItem, matching: .any(of: [.images, .videos]))
                    if media != .none {
                        Button("Remove media", role: .destructive) { media = .none }
                    }
                }
                Section("Note") {
                    TextField("How is \(animal.name) doing?", text: $note, axis: .vertical)
                        .lineLimit(3...8)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(HealthNotePresets.chips, id: \.self) { chip in
                                Button(chip) { insert(chip) }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Check in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(!canSave)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onChange(of: libraryItem) { _, item in
                guard let item else { return }
                Task {
                    if let loaded = await HealthLibraryLoader.load(item) {
                        media = loaded
                        errorMessage = nil
                    } else {
                        errorMessage = "Could not read that item from your library."
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var mediaPreview: some View {
        switch media {
        case .none:
            Label("No photo or video", systemImage: "photo.on.rectangle.angled")
                .foregroundStyle(.secondary)
        case .photo(let data):
            if let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                Label("Unreadable photo", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        case .video(let url):
            VideoPlayer(player: AVPlayer(url: url))
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func insert(_ chip: String) {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        note = trimmed.isEmpty ? chip : trimmed + ", " + chip
    }

    private func save() {
        do {
            try HealthStore.create(media: media, note: note, animal: animal, at: Date(),
                                   context: context, mediaStore: mediaStore)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
```

- [ ] **Step 8: Build and commit**

Run: `scripts/test-app.sh`
Expected: all tests pass, including the 4 new ones. Run `scripts/build-app.sh` and confirm `BUILD SUCCEEDED` (the sheet has no entry point until Task 8, so there is nothing to see on screen yet).

```bash
git add -A
git commit -m "feat(health): HealthStore create path, library loader, camera container, capture sheet

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: Health tab: Check in button, permission fallback, day-grouped list, tab wiring

**Files:**
- Create: `App/Views/Health/HealthMediaThumbnail.swift`, `App/Views/Health/HealthTabView.swift`
- Modify: `App/RootTabView.swift` (the Health tab line)
- Test: `AppTests/HealthListingTests.swift`

**Interfaces:**
- Consumes: `HealthCheckIn`, `PendingMedia`, `HealthCaptureSheet(animal:media:explanation:)`, `HealthCameraContainer(onPhoto:onVideo:)`, `HealthLibraryLoader.load(_:)`, `RecordListing.sections(_:animalID:calendar:animal:timestamp:)`, `DayGrouping.title(for:now:calendar:)`, `CameraCaptureView.isCameraAvailable`, `@Environment(\.mediaStore)`, `@Environment(\.selectedAnimal)`.
- Produces: `HealthMediaThumbnail(checkIn:size:)`; `HealthTabView()`. Task 9 adds `HealthCheckInDetailView(checkIn:)`, which this task's row button presents.

**Adds 2 tests.**

- [ ] **Step 1: Write the failing tests**

`AppTests/HealthListingTests.swift`:
```swift
import SwiftData
import XCTest
@testable import AnimalTracker

@MainActor
final class HealthListingTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()

    private func date(_ iso: String) -> Date {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: iso)!
    }

    func testSectionsShowOneAnimalNewestFirst() throws {
        let context = try TestSupport.container().mainContext
        let mine = Animal(name: "Juniper", species: "horse")
        let theirs = Animal(name: "Rex", species: "dog")
        context.insert(mine)
        context.insert(theirs)
        context.insert(HealthCheckIn(timestamp: date("2026-09-18 08:00"), note: "morning", animal: mine))
        context.insert(HealthCheckIn(timestamp: date("2026-09-18 19:00"), note: "evening", animal: mine))
        context.insert(HealthCheckIn(timestamp: date("2026-09-17 09:00"), note: "yesterday", animal: mine))
        context.insert(HealthCheckIn(timestamp: date("2026-09-18 10:00"), note: "other animal", animal: theirs))
        try context.save()

        let all = try context.fetch(FetchDescriptor<HealthCheckIn>())
        let sections = RecordListing.sections(all, animalID: mine.id, calendar: calendar,
                                              animal: { $0.animal?.id }, timestamp: { $0.timestamp })
        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(sections[0].items.map(\.note), ["evening", "morning"])
        XCTAssertEqual(sections[1].items.map(\.note), ["yesterday"])
        XCTAssertEqual(DayGrouping.title(for: sections[0].day, now: date("2026-09-18 21:00"), calendar: calendar), "Today")
    }

    func testMediaKindsAreDistinguishable() throws {
        let context = try TestSupport.container().mainContext
        let animal = Animal(name: "Juniper", species: "horse")
        context.insert(animal)
        let photo = HealthCheckIn(timestamp: date("2026-09-18 08:00"), photoFilename: "a-photo.jpg",
                                  thumbnailFilename: "a-thumb.jpg", animal: animal)
        let video = HealthCheckIn(timestamp: date("2026-09-18 09:00"), videoFilename: "a-video.mov", animal: animal)
        let noteOnly = HealthCheckIn(timestamp: date("2026-09-18 10:00"), note: "off food", animal: animal)
        context.insert(photo)
        context.insert(video)
        context.insert(noteOnly)
        try context.save()

        XCTAssertTrue(photo.hasMedia)
        XCTAssertTrue(video.hasMedia)
        XCTAssertFalse(noteOnly.hasMedia)
        XCTAssertNil(video.thumbnailFilename)
        XCTAssertEqual(photo.thumbnailFilename, "a-thumb.jpg")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test-app.sh`
Expected: the two new tests fail to compile only if `RecordListing` is missing; if Task 3 is done they should compile. Run them and confirm they pass before writing the views, then continue. (This task's real deliverable is the tab; the tests pin the listing behavior the tab depends on.)

- [ ] **Step 3: Write the thumbnail**

`App/Views/Health/HealthMediaThumbnail.swift`:
```swift
import SwiftUI

/// Photo thumbnail, video badge, or note icon. A file missing from disk falls back to a placeholder glyph.
struct HealthMediaThumbnail: View {
    let checkIn: HealthCheckIn
    var size: CGFloat = 52
    @Environment(\.mediaStore) private var mediaStore

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.15))
            if let thumb = checkIn.thumbnailFilename,
               mediaStore.exists(thumb),
               let image = UIImage(contentsOfFile: mediaStore.url(for: thumb).path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if checkIn.photoFilename != nil {
                Image(systemName: "photo").font(.title3).foregroundStyle(.secondary)
            } else if let video = checkIn.videoFilename {
                Image(systemName: mediaStore.exists(video) ? "play.rectangle.fill" : "play.slash")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "note.text").font(.title3).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
    }
}
```

- [ ] **Step 4: Write the tab**

`App/Views/Health/HealthTabView.swift`:
```swift
import AVFoundation
import PhotosUI
import SwiftData
import SwiftUI

/// One tap from "Check in" to the camera. No NavigationStack here: RootTabView supplies one.
struct HealthTabView: View {
    @Environment(\.selectedAnimal) private var animal
    @Query(sort: \HealthCheckIn.timestamp, order: .reverse) private var allCheckIns: [HealthCheckIn]

    @State private var showCamera = false
    @State private var showSheet = false
    @State private var pending: PendingMedia = .none
    @State private var explanation: String?
    @State private var libraryItem: PhotosPickerItem?
    @State private var detail: HealthCheckIn?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let animal {
                list(for: animal)
                    .fullScreenCover(isPresented: $showCamera) {
                        HealthCameraContainer(
                            onPhoto: { data in openSheet(with: .photo(data)) },
                            onVideo: { url in openSheet(with: .video(url)) }
                        )
                    }
                    .sheet(isPresented: $showSheet) {
                        HealthCaptureSheet(animal: animal, media: pending, explanation: explanation)
                    }
                    .fullScreenCover(item: $detail) { checkIn in
                        HealthCheckInDetailView(checkIn: checkIn)
                    }
            } else {
                ContentUnavailableView("No animal selected",
                                       systemImage: "pawprint",
                                       description: Text("Add or select an animal to check in."))
            }
        }
        .alert("Check in",
               isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
        .onChange(of: libraryItem) { _, item in
            guard let item else { return }
            Task {
                if let loaded = await HealthLibraryLoader.load(item) {
                    libraryItem = nil
                    openSheet(with: loaded)
                } else {
                    errorMessage = "Could not read that item from your library."
                }
            }
        }
    }

    private func sections(for animal: Animal) -> [DaySection<HealthCheckIn>] {
        RecordListing.sections(allCheckIns,
                               animalID: animal.id,
                               animal: { $0.animal?.id },
                               timestamp: { $0.timestamp })
    }

    private func list(for animal: Animal) -> some View {
        List {
            Section {
                Button {
                    startCheckIn()
                } label: {
                    Label("Check in", systemImage: "camera.fill")
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 56)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)
                HStack {
                    Button("Note only") { openSheet(with: .none) }
                    Spacer()
                    PhotosPicker("From library", selection: $libraryItem, matching: .any(of: [.images, .videos]))
                }
            }
            let sections = sections(for: animal)
            if sections.isEmpty {
                Section {
                    Text("No check-ins yet for \(animal.name).").foregroundStyle(.secondary)
                }
            }
            ForEach(sections) { section in
                Section(DayGrouping.title(for: section.day)) {
                    ForEach(section.items) { checkIn in
                        Button { detail = checkIn } label: { row(checkIn) }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func row(_ checkIn: HealthCheckIn) -> some View {
        HStack(spacing: 12) {
            HealthMediaThumbnail(checkIn: checkIn)
            VStack(alignment: .leading, spacing: 4) {
                Text(checkIn.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.subheadline.monospacedDigit())
                if let note = checkIn.note, !note.isEmpty {
                    Text(note).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                } else {
                    Text(checkIn.videoFilename != nil ? "Video" : "Photo")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .foregroundStyle(.primary)
    }

    private func openSheet(with media: PendingMedia, explanation: String? = nil) {
        pending = media
        self.explanation = explanation
        showSheet = true
    }

    /// One tap to the camera when it is available and allowed; otherwise the note-only sheet explains why.
    private func startCheckIn() {
        guard CameraCaptureView.isCameraAvailable else {
            openSheet(with: .none, explanation: "This device has no camera, so this check-in is note only. You can still attach a photo or video from your library.")
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            showCamera = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    if granted { showCamera = true } else { openDeniedSheet() }
                }
            }
        default:
            openDeniedSheet()
        }
    }

    private func openDeniedSheet() {
        openSheet(with: .none, explanation: "Camera access is off for AnimalTracker, so this check-in is note only. Turn it on in Settings, AnimalTracker, Camera. You can still attach a photo or video from your library.")
    }
}
```

- [ ] **Step 5: Wire the tab**

In `App/RootTabView.swift`, replace this line:
```swift
            tab("Health", "heart.text.square") { Text("Health") }
```
with:
```swift
            tab("Health", "heart.text.square") { HealthTabView() }
```

The build fails until Task 9 supplies `HealthCheckInDetailView`. To keep this task independently committable, create the file now with the final Task 9 content, or add this one-line stub and replace it wholesale in Task 9:
```swift
// App/Views/Health/HealthCheckInDetailView.swift
import SwiftUI

struct HealthCheckInDetailView: View {
    let checkIn: HealthCheckIn
    var body: some View { Text(checkIn.timestamp.formatted()) }
}
```

- [ ] **Step 6: Build, run, look**

Run: `scripts/test-app.sh` (all tests pass), then `scripts/run-sim.sh`.
Read `build/screenshot.png`. On the Health tab with an animal selected, confirm: the large "Check in" button fills the width, "Note only" and "From library" sit under it, and the list says "No check-ins yet for <name>". Tap Check in: the simulator has no camera, so the note-only sheet opens with the "This device has no camera" explanation. Type a note, tap a chip, Save, and confirm a row appears under "Today" with the note icon, the time and the note preview.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat(health): Health tab with one-tap check in, camera permission fallback, day-grouped list

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 9: Full-screen check-in detail: zoom, playback, edit, add media, delete

**Files:**
- Modify: `App/Persistence/HealthStore.swift` (append four functions), `App/Views/Health/HealthCheckInDetailView.swift` (replace the Task 8 stub)
- Test: `AppTests/HealthDetailStoreTests.swift`

**Interfaces:**
- Consumes: `HealthCheckIn`, `HealthStore.create(...)`, `PendingMedia`, `HealthStoreError`, `HealthCheckInValidation`, `HealthNotePresets`, `MediaStore`, `InMemoryMediaStore`, `CameraCaptureView(mode:maxVideoSeconds:onPhoto:onVideo:)`, `HealthLibraryLoader.load(_:)`, `TestImages.jpeg(width:height:)`.
- Produces: `HealthStore.attachPhoto(_:to:context:mediaStore:) throws`, `HealthStore.attachVideo(from:to:context:mediaStore:) throws`, `HealthStore.update(_:timestamp:note:now:context:) throws`, `HealthStore.delete(_:context:mediaStore:) throws`; `HealthCheckInDetailView(checkIn:)`.

**Adds 5 tests.**

- [ ] **Step 1: Write the failing tests**

`AppTests/HealthDetailStoreTests.swift`:
```swift
import SwiftData
import XCTest
@testable import AnimalTracker

@MainActor
final class HealthDetailStoreTests: XCTestCase {
    private func fixture() throws -> (ModelContext, Animal, InMemoryMediaStore) {
        let context = try TestSupport.container().mainContext
        let animal = Animal(name: "Juniper", species: "horse")
        context.insert(animal)
        try context.save()
        return (context, animal, InMemoryMediaStore())
    }

    func testAttachPhotoSetsBothFilenamesAndStampsEditedAt() throws {
        let (context, animal, store) = try fixture()
        let checkIn = try HealthStore.create(media: .none, note: "off food", animal: animal, at: Date(),
                                             context: context, mediaStore: store)
        try HealthStore.attachPhoto(TestImages.jpeg(width: 800, height: 600), to: checkIn, context: context, mediaStore: store)
        let photo = try XCTUnwrap(checkIn.photoFilename)
        let thumb = try XCTUnwrap(checkIn.thumbnailFilename)
        XCTAssertTrue(store.exists(photo))
        XCTAssertTrue(store.exists(thumb))
        XCTAssertNotNil(checkIn.editedAt)
    }

    func testAttachPhotoReplacesAndDeletesTheOldFiles() throws {
        let (context, animal, store) = try fixture()
        let checkIn = try HealthStore.create(media: .photo(TestImages.jpeg(width: 400, height: 400)), note: "",
                                             animal: animal, at: Date(), context: context, mediaStore: store)
        let oldPhoto = try XCTUnwrap(checkIn.photoFilename)
        let oldThumb = try XCTUnwrap(checkIn.thumbnailFilename)
        try HealthStore.attachPhoto(TestImages.jpeg(width: 900, height: 300), to: checkIn, context: context, mediaStore: store)
        XCTAssertNotEqual(checkIn.photoFilename, oldPhoto)
        XCTAssertFalse(store.exists(oldPhoto))
        XCTAssertFalse(store.exists(oldThumb))
        XCTAssertTrue(store.exists(try XCTUnwrap(checkIn.photoFilename)))
    }

    func testAttachVideoCopiesTheFile() throws {
        let (context, animal, store) = try fixture()
        let checkIn = try HealthStore.create(media: .none, note: "limping", animal: animal, at: Date(),
                                             context: context, mediaStore: store)
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
        try Data([4, 5, 6]).write(to: source)
        try HealthStore.attachVideo(from: source, to: checkIn, context: context, mediaStore: store)
        let video = try XCTUnwrap(checkIn.videoFilename)
        XCTAssertTrue(video.hasSuffix("-video.mov"))
        XCTAssertTrue(store.exists(video))
        XCTAssertEqual(try Data(contentsOf: store.url(for: video)), Data([4, 5, 6]))
    }

    func testUpdateStampsEditedAtAndRefusesToEmptyACheckIn() throws {
        let (context, animal, store) = try fixture()
        let checkIn = try HealthStore.create(media: .none, note: "off food", animal: animal, at: Date(),
                                             context: context, mediaStore: store)
        let later = Date(timeIntervalSince1970: 1_780_000_000)
        try HealthStore.update(checkIn, timestamp: later, note: "  eating again  ", now: later, context: context)
        XCTAssertEqual(checkIn.timestamp, later)
        XCTAssertEqual(checkIn.note, "eating again")
        XCTAssertEqual(checkIn.editedAt, later)

        XCTAssertThrowsError(try HealthStore.update(checkIn, timestamp: later, note: "   ", now: later, context: context)) { error in
            XCTAssertEqual((error as? HealthStoreError)?.errorDescription, HealthCheckInValidation.invalidMessage)
        }
        XCTAssertEqual(checkIn.note, "eating again")
    }

    func testDeleteRemovesTheRecordAndItsMediaFiles() throws {
        let (context, animal, store) = try fixture()
        let checkIn = try HealthStore.create(media: .photo(TestImages.jpeg(width: 400, height: 400)), note: "swelling",
                                             animal: animal, at: Date(), context: context, mediaStore: store)
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
        try Data([7]).write(to: source)
        try HealthStore.attachVideo(from: source, to: checkIn, context: context, mediaStore: store)
        let photo = try XCTUnwrap(checkIn.photoFilename)
        let thumb = try XCTUnwrap(checkIn.thumbnailFilename)
        let video = try XCTUnwrap(checkIn.videoFilename)

        try HealthStore.delete(checkIn, context: context, mediaStore: store)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<HealthCheckIn>()), 0)
        XCTAssertFalse(store.exists(photo))
        XCTAssertFalse(store.exists(thumb))
        XCTAssertFalse(store.exists(video))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test-app.sh`
Expected: build errors, `HealthStore.attachPhoto`, `attachVideo`, `update` and `delete` not found.

- [ ] **Step 3: Extend the store**

Append these four functions inside `enum HealthStore` in `App/Persistence/HealthStore.swift`:
```swift
    /// Writes the new photo first, then drops the old files, so a failed write leaves the check-in intact.
    static func attachPhoto(_ data: Data, to checkIn: HealthCheckIn, context: ModelContext, mediaStore: MediaStore) throws {
        let saved: SavedPhoto
        do { saved = try mediaStore.savePhoto(data) }
        catch { throw HealthStoreError.media(error.localizedDescription) }
        let oldPhoto = checkIn.photoFilename
        let oldThumb = checkIn.thumbnailFilename
        checkIn.photoFilename = saved.filename
        checkIn.thumbnailFilename = saved.thumbnailFilename
        checkIn.editedAt = Date()
        do {
            try context.save()
        } catch {
            mediaStore.delete(saved.filename)
            mediaStore.delete(saved.thumbnailFilename)
            checkIn.photoFilename = oldPhoto
            checkIn.thumbnailFilename = oldThumb
            throw error
        }
        if let oldPhoto { mediaStore.delete(oldPhoto) }
        if let oldThumb { mediaStore.delete(oldThumb) }
    }

    static func attachVideo(from url: URL, to checkIn: HealthCheckIn, context: ModelContext, mediaStore: MediaStore) throws {
        let name: String
        do { name = try mediaStore.saveVideo(from: url) }
        catch { throw HealthStoreError.media(error.localizedDescription) }
        let old = checkIn.videoFilename
        checkIn.videoFilename = name
        checkIn.editedAt = Date()
        do {
            try context.save()
        } catch {
            mediaStore.delete(name)
            checkIn.videoFilename = old
            throw error
        }
        if let old { mediaStore.delete(old) }
    }

    /// Refuses an edit that would leave the check-in with no photo, no video and no note.
    static func update(_ checkIn: HealthCheckIn, timestamp: Date, note: String, now: Date, context: ModelContext) throws {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard HealthCheckInValidation.isValid(photoFilename: checkIn.photoFilename,
                                              videoFilename: checkIn.videoFilename,
                                              note: trimmed) else {
            throw HealthStoreError.nothingToSave
        }
        checkIn.timestamp = timestamp
        checkIn.note = trimmed.isEmpty ? nil : trimmed
        checkIn.editedAt = now
        try context.save()
    }

    /// Deleting a check-in deletes its files.
    static func delete(_ checkIn: HealthCheckIn, context: ModelContext, mediaStore: MediaStore) throws {
        let names = [checkIn.photoFilename, checkIn.thumbnailFilename, checkIn.videoFilename].compactMap { $0 }
        context.delete(checkIn)
        try context.save()
        for name in names { mediaStore.delete(name) }
    }
```

- [ ] **Step 4: Run to verify pass**

Run: `scripts/test-app.sh`
Expected: the 5 new `HealthDetailStoreTests` pass.

- [ ] **Step 5: Write the detail view**

`App/Views/Health/HealthCheckInDetailView.swift` (replace the Task 8 stub entirely):
```swift
import AVKit
import PhotosUI
import SwiftData
import SwiftUI

/// Full-screen check-in: zoomable photo, playable video, editable note and time, add missing media, delete.
struct HealthCheckInDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.mediaStore) private var mediaStore
    @Environment(\.dismiss) private var dismiss

    let checkIn: HealthCheckIn

    @State private var timestamp = Date()
    @State private var note = ""
    @State private var cameraMode: CameraCaptureView.Mode = .photo
    @State private var showCamera = false
    @State private var libraryItem: PhotosPickerItem?
    @State private var confirmDelete = false
    @State private var errorMessage: String?
    @State private var scale: CGFloat = 1
    @State private var committedScale: CGFloat = 1

    var body: some View {
        NavigationStack {
            Form {
                Section { mediaView }
                Section("Time") {
                    DatePicker("Time", selection: $timestamp)
                }
                Section("Note") {
                    TextField("Note", text: $note, axis: .vertical).lineLimit(3...10)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(HealthNotePresets.chips, id: \.self) { chip in
                                Button(chip) { insert(chip) }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                Section("Media") {
                    if checkIn.photoFilename == nil {
                        Button("Add photo") { cameraMode = .photo; showCamera = true }
                    }
                    if checkIn.videoFilename == nil {
                        Button("Add video") { cameraMode = .video; showCamera = true }
                    }
                    PhotosPicker("Add from library", selection: $libraryItem, matching: .any(of: [.images, .videos]))
                }
                Section {
                    Button("Delete check-in", role: .destructive) { confirmDelete = true }
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Check-in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) }
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .onAppear {
                timestamp = checkIn.timestamp
                note = checkIn.note ?? ""
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraCaptureView(mode: cameraMode,
                                  maxVideoSeconds: 60,
                                  onPhoto: { data in attach(.photo(data)) },
                                  onVideo: { url in attach(.video(url)) })
                    .ignoresSafeArea()
            }
            .onChange(of: libraryItem) { _, item in
                guard let item else { return }
                Task {
                    if let loaded = await HealthLibraryLoader.load(item) {
                        libraryItem = nil
                        attach(loaded)
                    } else {
                        errorMessage = "Could not read that item from your library."
                    }
                }
            }
            .confirmationDialog("Delete this check-in and its photo or video?",
                                isPresented: $confirmDelete,
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) { deleteCheckIn() }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    @ViewBuilder
    private var mediaView: some View {
        if let photo = checkIn.photoFilename {
            if mediaStore.exists(photo), let image = UIImage(contentsOfFile: mediaStore.url(for: photo).path) {
                ScrollView([.horizontal, .vertical], showsIndicators: false) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 320 * scale, height: 320 * scale)
                        .gesture(
                            MagnificationGesture()
                                .onChanged { value in scale = min(4, max(1, committedScale * value)) }
                                .onEnded { _ in committedScale = scale }
                        )
                        .onTapGesture(count: 2) {
                            scale = scale > 1 ? 1 : 2
                            committedScale = scale
                        }
                }
                .frame(height: 320)
                .accessibilityLabel("Check-in photo, pinch or double tap to zoom")
            } else {
                missingMedia("This photo is missing from Documents/Media.")
            }
        } else if let video = checkIn.videoFilename {
            if mediaStore.exists(video) {
                VideoPlayer(player: AVPlayer(url: mediaStore.url(for: video)))
                    .frame(height: 260)
            } else {
                missingMedia("This video is missing from Documents/Media.")
            }
        } else {
            Label("Note only", systemImage: "note.text").foregroundStyle(.secondary)
        }
    }

    private func missingMedia(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.secondary)
            Text(message).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }

    private func insert(_ chip: String) {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        note = trimmed.isEmpty ? chip : trimmed + ", " + chip
    }

    private func attach(_ media: PendingMedia) {
        do {
            switch media {
            case .none:
                break
            case .photo(let data):
                try HealthStore.attachPhoto(data, to: checkIn, context: context, mediaStore: mediaStore)
            case .video(let url):
                try HealthStore.attachVideo(from: url, to: checkIn, context: context, mediaStore: mediaStore)
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save() {
        do {
            try HealthStore.update(checkIn, timestamp: timestamp, note: note, now: Date(), context: context)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteCheckIn() {
        do {
            try HealthStore.delete(checkIn, context: context, mediaStore: mediaStore)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
```

- [ ] **Step 6: Build, run, look**

Run: `scripts/test-app.sh` (all tests pass), then `scripts/run-sim.sh`.
Read `build/screenshot.png`. Tap a check-in row: the detail opens full screen. Confirm a note-only check-in shows "Note only" with Add photo, Add video and Add from library; attaching a library photo shows it and pinch zooms it; the time picker and note edit and save; Delete asks for confirmation and, after deleting, the row and its thumbnail are gone from the list. To see the missing-file placeholder, delete the file from the simulator container and reopen the detail:
```bash
SIM="$(xcrun simctl list devices available | grep -m1 -oE 'iPhone [^(]+' | sed 's/ *$//')"
CONTAINER="$(xcrun simctl get_app_container "$SIM" com.ashlab.AnimalTracker data)"
ls "$CONTAINER/Documents/Media"
rm "$CONTAINER/Documents/Media/"*-photo.jpg
```

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat(health): full-screen check-in detail with zoom, playback, editing, media attach and delete

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Self-review

**Spec coverage.** Poop domain models and the 14 seeded tags: Tasks 1 and 2. Poop tab quick-add with multi-select chips in tag colors, note, Save disabled at zero tags, insert for the selected animal at the current time, selection cleared: Task 4. Observations grouped by day newest first with time, chips, note preview, swipe to delete, tap to edit with editedAt: Tasks 3 and 4. Manage tags in Settings, rename and hide built-ins, add custom tags with palette colors, delete custom tags only when unused, reorder: Task 5. Health domain model, at-least-one-of rule, deletion policy: Task 6. One-tap Check in to the camera with a video switch capped at 60 s, post-capture sheet with media, optional note, the nine quick-insert chips, Save, Note only, From library copied into the media store, camera unavailable or denied falling back to the note-only sheet with an explanation: Tasks 7 and 8. Check-ins grouped by day with thumbnail, video badge or note icon, time and note preview: Task 8. Full-screen detail with zoomable photo, AVKit playback, editable note and timestamp, Add photo and Add video when missing, Delete with confirmation that also deletes the files: Task 9. Error handling: media write failures throw `HealthStoreError.media` and nothing is saved (Task 7 test), missing files show a placeholder (Tasks 8 and 9), deleting a tag in use is blocked with an explanation (Task 5). Registration points: `modelTypes` (Tasks 1 and 6), `Seeds.all` (Task 2), `AnimalDeletionPolicy.recordCounts` (Tasks 1 and 6), the two `RootTabView` lines (Tasks 4 and 8), the `SettingsView` row (Task 5), `Snapshots.swift` (Tasks 1 and 6). Out of this plan's scope by design: CSV and JSON export of these domains (Plan G) and the oral check-in's poop and health mapping (Plan F).

**Placeholder scan.** No "TBD", no "similar to Task N", no "add validation". Every code step carries the full file or the exact replacement lines. The only stub in the plan is `HealthCheckInDetailView` in Task 8 Step 5, which exists so Task 8 builds on its own; Task 9 Step 5 replaces it with the complete file and says so.

**Type consistency.** `MediaStore` is used exactly as Plan A defines it: `savePhoto(_:) -> SavedPhoto` with `filename` and `thumbnailFilename`, `saveVideo(from:) -> String`, `saveAudio(from:) -> String`, `url(for:)`, `exists(_:)`, `delete(_:)`; `FailingMediaStore` in Task 7 implements all six. `CameraCaptureView(mode:maxVideoSeconds:onPhoto:onVideo:)` and `CameraCaptureView.isCameraAvailable` match Plan A. `PendingMedia` is declared once, in `App/Persistence/HealthStore.swift` (Task 7), and used by Tasks 8 and 9. `PoopTagInfo` is declared once, in `App/Logic/PoopTagRules.swift` (Task 3), and used by Tasks 4 and 5. `DaySection`/`DayGrouping`/`RecordListing` are declared once (Task 3) and used by Tasks 4 and 8. `PoopStore.add(tags:note:animal:at:context:)`, `PoopStore.update(_:timestamp:tags:note:now:context:)` and `PoopStore.delete(_:context:)` keep the same labels in Task 4's tests and views. `HealthStore.create(media:note:animal:at:context:mediaStore:)` in Task 7 is called with the same labels in Tasks 8 and 9. Model field names match the contract exactly, including `HealthCheckIn.thumbnailFilename`, which the contract lists and the spec's prose omits. `PoopSnapshot` and `HealthSnapshot` carry exactly the contract's fields, and neither includes a thumbnail field.
