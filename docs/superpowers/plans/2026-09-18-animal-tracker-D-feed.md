# AnimalTracker Plan D: Feed Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Feed subsystem: the FeedDay, Feeding and FeedItem models, pure suggestion and clamp logic, a day store, and the Feed tab with its day card and feeding editor.

**Architecture:** Three SwiftData models registered in the shared container. All logic that can be pure is pure: `FeedSuggestions`, `FeedClamps` and `FeedFormatting` take snapshots and text and return values, with no SwiftData import, so their tests never open a container. Everything that touches the store goes through one helper, `FeedDayStore`, so views stay thin and every fetch and write has a test. The feeding editor edits an array of `FeedItemDraft` values and only writes on Save, which is what makes Cancel undo "Copy last feeding".

**Tech Stack:** Swift 5 language mode, SwiftUI, SwiftData, XCTest. No third-party packages.

**Spec:** `docs/superpowers/specs/2026-09-16-animal-tracker-design.md` (sections: Constraints, Top-level navigation, Data model/Feed domain, Feed tab, Logic, Error handling, Testing) and `docs/superpowers/specs/2026-09-18-model-contract.md` (binding model and snapshot names). Builds on `docs/superpowers/plans/2026-09-18-animal-tracker-A-foundation.md`, which is fully implemented before this plan runs.

## Global Constraints

- iOS deployment target `17.0`; Swift 5 language mode (`SWIFT_VERSION = 5.0`); never Swift 6 strict concurrency.
- SwiftUI and SwiftData only. No third-party packages, no iCloud, no network use anywhere in this plan.
- App target `AnimalTracker`, test target `AnimalTrackerTests`. Test files use `@testable import AnimalTracker`.
- Every model has `var id: UUID = UUID()` and `var createdAt: Date = Date()`. Every stored property has a default or is optional. Relationships are optional. One side declares `@Relationship(deleteRule:inverse:)`, the other is a plain optional.
- Enum-backed fields are stored as `<name>Raw: String` with a computed `<name>` accessor.
- Tests: XCTest in `AppTests/`, run with `scripts/test-app.sh`. Tests needing the store use `TestSupport.container()` (in-memory). Pure logic tests must not touch SwiftData.
- Visual checks: `scripts/run-sim.sh`, then read `build/screenshot.png`.
- Tab root views must not create their own `NavigationStack`. Plan A's `RootTabView` supplies one per tab with the shared toolbar. Tab roots read the animal via `@Environment(\.selectedAnimal)` and show an empty state when it is nil.
- Numeric clamps, verbatim from the spec: outdoor hours 0 to 24, acres and amounts >= 0.
- Feed tab section titles, verbatim from the spec: Forage, Food, Supplements, Treats.
- Suggestions for `type` and `unit` are derived at query time from the selected animal's existing FeedItem values per category, most recent first, falling back to all animals.
- SwiftData save failures surface as an alert and the change is not shown as saved.
- Commit after every task with the message shown. Do not push. Every commit message ends with the trailer line `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Test counts below are written as "19 + Plan C's tests + N": Plan A ends at 19 tests, Plan C runs before this plan and adds its own.

## Assumptions

Decisions the spec left open, and how this plan resolves them.

1. **FeedDay uniqueness.** The contract says "unique per animal by convention", so there is no `@Attribute(.unique)`. `FeedDayStore.day(for:on:context:)` is the only creator, and it finds before it creates.
2. **Relationship predicates.** `#Predicate` over an optional to-one relationship (`$0.animal?.id == id`) is unreliable on iOS 17, so every animal-scoped fetch filters on the fetched objects in Swift instead. Date ranges, which are plain stored properties, still use a predicate. Feed data is one row per day per animal, so the cost is irrelevant.
3. **New files beyond the spec's project layout.** The layout lists `Logic/FeedSuggestions.swift` only. This plan adds `Logic/FeedClamps.swift`, `Logic/FeedFormatting.swift`, `Logic/FeedItemDraft.swift` and `Persistence/FeedDayStore.swift` so each unit stays small and separately testable.
4. **Navigation from the tab root.** The tab root cannot own a `NavigationStack`, but the "Today" button has to push programmatically, so the list uses `.navigationDestination(item:)` (iOS 17) with a `@State` selection and plain rows as buttons, rather than `NavigationLink(value:)`.
5. **Suggestion fallback granularity.** The fallback to all animals is applied per list: if the selected animal has no types in that category, the category's types come from all animals; the same for units. It is not an all-or-nothing switch over the whole editor.
6. **Chip count.** Suggestion chip rows show the 8 most recent suggestions; the rest stay reachable by typing.
7. **Default time for a new feeding.** The current clock time applied to the day being edited, so adding a feeding to an older day does not date it today.
8. **Day card saves immediately.** Only the feeding editor uses drafts, because only the editor has a Cancel that must undo "Copy last feeding". The day card writes outdoor hours, acres and note through `FeedDayStore.updateDay` as they change, clamped on every write.
9. **Confirmation scope.** The spec requires confirmation only for deleting a day. Deleting a feeding or an item is a plain swipe with no dialog.
10. **Blank rows.** A draft item with a blank type is dropped on save rather than stored as an empty item.
11. **Decimal separator.** Amount, hours and acres fields accept "." or "," so a comma-locale keyboard works.
12. **No seed, no settings row.** The feed domain has nothing to seed, so `Seeds.all` is untouched, and the spec gives Settings no feed row, so no `SettingsPlaceholderRow` is replaced.

## File Structure

```
App/Models/FeedDay.swift                     FeedDay model (cascade to feedings)
App/Models/Feeding.swift                     Feeding model (cascade to items)
App/Models/FeedItem.swift                    FeedItem model + category accessor
App/Logic/Snapshots.swift                    MODIFY: add FeedingSnapshot, FeedItemSnapshot
App/Logic/FeedSuggestions.swift              pure type and unit suggestions
App/Logic/FeedClamps.swift                   pure numeric clamps and decimal parsing
App/Logic/FeedFormatting.swift               pure row text for the tab and day card
App/Logic/FeedItemDraft.swift                pure editable row value for the editor
App/Persistence/FeedDayStore.swift           find-or-create day, fetches, deletes, feeding save
App/Persistence/PersistenceController.swift  MODIFY: register the three models
App/Persistence/AnimalDeletionPolicy.swift   MODIFY: "feed days" record count
App/RootTabView.swift                        MODIFY: real Feed tab root
App/Views/Feed/FeedTabView.swift             day list, Today button, delete confirmation
App/Views/Feed/FeedDayCardView.swift         outdoor fields, note, feedings, Add Feeding
App/Views/Feed/FeedingEditorView.swift       time, four sections, items, note, Copy last feeding
App/Views/Feed/SuggestionChipsView.swift     horizontal tappable suggestions
AppTests/FeedModelTests.swift                models and deletion policy
AppTests/FeedSuggestionsTests.swift          pure suggestions
AppTests/FeedSnapshotTests.swift             snapshot conversion
AppTests/FeedClampsTests.swift               pure clamps
AppTests/FeedFormattingTests.swift           pure row text
AppTests/FeedDayStoreTests.swift             find-or-create, fetches, delete
AppTests/FeedingSaveTests.swift              draft-to-store save
AppTests/FeedCopyLastTests.swift             most recent feeding lookup
```

---

### Task 1: Feed models and registration

**Files:**
- Create: `App/Models/FeedDay.swift`, `App/Models/Feeding.swift`, `App/Models/FeedItem.swift`
- Modify: `App/Persistence/PersistenceController.swift` (the `modelTypes` array)
- Modify: `App/Persistence/AnimalDeletionPolicy.swift` (`recordCounts`)
- Test: `AppTests/FeedModelTests.swift`

**Interfaces:**
- Consumes: `Animal`, `FeedCategory` (cases `forage`, `food`, `supplement`, `treat`), `PersistenceController.modelTypes`, `AnimalDeletionPolicy.recordCounts(for:context:)`, `TestSupport.container()`, all from Plan A.
- Produces: `FeedDay(date:animal:)` with `id, createdAt, date, outdoorHours, outdoorAreaAcres, note, animal, feedings`; `Feeding(time:note:)` with `id, createdAt, time, note, day, items`; `FeedItem(category:type:amount:unit:sortOrder:)` with `id, createdAt, categoryRaw, category, type, amount, unit, sortOrder, feeding`; `AnimalDeletionPolicy.recordCounts` key `"feed days"`.

- [ ] **Step 1: Write the failing test**

`AppTests/FeedModelTests.swift`:
```swift
import SwiftData
import XCTest
@testable import AnimalTracker

@MainActor
final class FeedModelTests: XCTestCase {
    func testFeedModelsRoundTripWithDefaults() throws {
        let context = try TestSupport.container().mainContext
        let animal = Animal(name: "Juniper", species: "horse")
        context.insert(animal)
        let day = FeedDay(date: Calendar.current.startOfDay(for: Date()), animal: animal)
        context.insert(day)
        let feeding = Feeding(time: Date())
        context.insert(feeding)
        feeding.day = day
        let item = FeedItem(category: .forage, type: "hay", amount: 2, unit: "flakes", sortOrder: 0)
        context.insert(item)
        item.feeding = feeding
        try context.save()

        let days = try context.fetch(FetchDescriptor<FeedDay>())
        XCTAssertEqual(days.count, 1)
        XCTAssertNil(days[0].outdoorHours)
        XCTAssertNil(days[0].outdoorAreaAcres)
        XCTAssertNil(days[0].note)
        XCTAssertEqual(days[0].animal?.id, animal.id)
        XCTAssertEqual(days[0].feedings?.count, 1)
        XCTAssertEqual(days[0].feedings?.first?.items?.count, 1)
        XCTAssertEqual(days[0].feedings?.first?.items?.first?.type, "hay")
        XCTAssertEqual(days[0].feedings?.first?.items?.first?.amount, 2)
        XCTAssertEqual(days[0].feedings?.first?.items?.first?.unit, "flakes")
    }

    func testCategoryAccessorReadsAndWritesRaw() {
        let item = FeedItem()
        XCTAssertEqual(item.categoryRaw, "forage")
        XCTAssertEqual(item.category, .forage)
        item.category = .supplement
        XCTAssertEqual(item.categoryRaw, "supplement")
        item.categoryRaw = "nonsense"
        XCTAssertEqual(item.category, .forage)
    }

    func testDeletionPolicyCountsFeedDays() throws {
        let context = try TestSupport.container().mainContext
        let animal = Animal(name: "Juniper", species: "horse")
        context.insert(animal)
        try context.save()
        XCTAssertEqual(try AnimalDeletionPolicy.recordCounts(for: animal, context: context)["feed days"], 0)
        XCTAssertTrue(try AnimalDeletionPolicy.canDelete(animal, context: context))

        let day = FeedDay(date: Calendar.current.startOfDay(for: Date()), animal: animal)
        context.insert(day)
        try context.save()
        XCTAssertEqual(try AnimalDeletionPolicy.recordCounts(for: animal, context: context)["feed days"], 1)
        XCTAssertFalse(try AnimalDeletionPolicy.canDelete(animal, context: context))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test-app.sh`
Expected: build errors, `FeedDay`, `Feeding`, `FeedItem` not found.

- [ ] **Step 3: Write the implementation**

`App/Models/FeedDay.swift`:
```swift
import Foundation
import SwiftData

/// One calendar day of feed for one animal. Local start of day, unique per animal by convention
/// (FeedDayStore is the only creator and finds before it creates).
@Model
final class FeedDay {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var date: Date = Calendar.current.startOfDay(for: Date())
    /// 0 to 24; shown only when the animal tracksOutdoorTime.
    var outdoorHours: Double?
    /// >= 0; same visibility.
    var outdoorAreaAcres: Double?
    var note: String?
    var animal: Animal?
    @Relationship(deleteRule: .cascade, inverse: \Feeding.day) var feedings: [Feeding]?

    init(date: Date = Calendar.current.startOfDay(for: Date()), animal: Animal? = nil) {
        self.date = date
        self.animal = animal
    }
}
```

`App/Models/Feeding.swift`:
```swift
import Foundation
import SwiftData

/// One feeding within a day: a time, an optional note, and its items.
@Model
final class Feeding {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var time: Date = Date()
    var note: String?
    var day: FeedDay?
    @Relationship(deleteRule: .cascade, inverse: \FeedItem.feeding) var items: [FeedItem]?

    init(time: Date = Date(), note: String? = nil) {
        self.time = time
        self.note = note
    }
}
```

`App/Models/FeedItem.swift`:
```swift
import Foundation
import SwiftData

/// One line of a feeding: "hay, 2 flakes". Hay is a forage item; there are no hay-specific fields.
@Model
final class FeedItem {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var categoryRaw: String = FeedCategory.forage.rawValue
    var type: String = ""
    var amount: Double = 0
    var unit: String = ""
    /// Position within its category in the feeding editor.
    var sortOrder: Int = 0
    var feeding: Feeding?

    var category: FeedCategory {
        get { FeedCategory(rawValue: categoryRaw) ?? .forage }
        set { categoryRaw = newValue.rawValue }
    }

    init(category: FeedCategory = .forage, type: String = "", amount: Double = 0, unit: String = "", sortOrder: Int = 0) {
        self.categoryRaw = category.rawValue
        self.type = type
        self.amount = amount
        self.unit = unit
        self.sortOrder = sortOrder
    }
}
```

In `App/Persistence/PersistenceController.swift`, add three lines to the `modelTypes` array, keeping whatever earlier plans registered. After this task the array reads (the `AACButton` and `Press` lines are Plan C's; if Plan C has not run they are absent and you add only the three feed lines):
```swift
    static let modelTypes: [any PersistentModel.Type] = [
        Animal.self,
        AACButton.self,
        Press.self,
        FeedDay.self,
        Feeding.self,
        FeedItem.self,
    ]
```

In `App/Persistence/AnimalDeletionPolicy.swift`, `recordCounts(for:context:)` currently returns an empty dictionary (Plan A) or a dictionary with Plan C's entries. Add the feed entry. If a `let animalID = animal.id` line already exists from an earlier plan, do not add a second one, and delete any leftover `_ = animal` or `_ = context` discard lines. The body after this task:
```swift
    static func recordCounts(for animal: Animal, context: ModelContext) throws -> [String: Int] {
        var counts: [String: Int] = [:]
        let animalID = animal.id
        let days = try context.fetch(FetchDescriptor<FeedDay>()).filter { $0.animal?.id == animalID }
        counts["feed days"] = days.count
        return counts
    }
```
Note for the reader: the animal filter runs in Swift rather than in a `#Predicate` because predicates over an optional to-one relationship are unreliable on iOS 17. Plan C's entries, if present, stay exactly as they are; only the two feed lines and the `counts["feed days"]` assignment are added.

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test-app.sh`
Expected: PASS, 3 new tests (19 + Plan C's tests + 3).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(feed): FeedDay, Feeding and FeedItem models with registration

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: Feed snapshots and FeedSuggestions

**Files:**
- Modify: `App/Logic/Snapshots.swift` (append two structs)
- Create: `App/Logic/FeedSuggestions.swift`
- Test: `AppTests/FeedSuggestionsTests.swift`, `AppTests/FeedSnapshotTests.swift`

**Interfaces:**
- Consumes: `FeedDay`, `Feeding`, `FeedItem`, `FeedCategory`, `AnimalSnapshot`'s file.
- Produces: `FeedItemSnapshot(id:category:type:amount:unit:sortOrder:createdAt:)` plus `init(_ item: FeedItem)`; `FeedingSnapshot(id:time:note:items:)` plus `init(_ feeding: Feeding)` which sorts items by category order, then sortOrder, then createdAt; `FeedSuggestions.types(_ items: [FeedItemSnapshot], category: FeedCategory) -> [String]` and `FeedSuggestions.units(_ items: [FeedItemSnapshot]) -> [String]`.

- [ ] **Step 1: Write the failing tests**

`AppTests/FeedSuggestionsTests.swift`:
```swift
import XCTest
@testable import AnimalTracker

final class FeedSuggestionsTests: XCTestCase {
    private func item(_ type: String, _ unit: String, _ category: FeedCategory, minutesAgo: Double) -> FeedItemSnapshot {
        FeedItemSnapshot(id: UUID(), category: category, type: type, amount: 1, unit: unit, sortOrder: 0,
                         createdAt: Date(timeIntervalSince1970: 1_700_000_000 - minutesAgo * 60))
    }

    func testTypesAreFilteredByCategoryNewestFirst() {
        let items = [item("hay", "flakes", .forage, minutesAgo: 30),
                     item("haylage", "kg", .forage, minutesAgo: 5),
                     item("Purina Senior", "scoop", .food, minutesAgo: 1)]
        XCTAssertEqual(FeedSuggestions.types(items, category: .forage), ["haylage", "hay"])
        XCTAssertEqual(FeedSuggestions.types(items, category: .food), ["Purina Senior"])
        XCTAssertEqual(FeedSuggestions.types(items, category: .treat), [])
    }

    func testCaseInsensitiveDedupeKeepsMostRecentCasing() {
        let items = [item("hay", "Flakes", .forage, minutesAgo: 60),
                     item("HAY", "flakes", .forage, minutesAgo: 10)]
        XCTAssertEqual(FeedSuggestions.types(items, category: .forage), ["HAY"])
        XCTAssertEqual(FeedSuggestions.units(items), ["flakes"])
    }

    func testUnitsSpanEveryCategoryAndSkipBlanks() {
        let items = [item("hay", "flakes", .forage, minutesAgo: 20),
                     item("MSM", "   ", .supplement, minutesAgo: 10),
                     item("carrot", "pieces", .treat, minutesAgo: 1)]
        XCTAssertEqual(FeedSuggestions.units(items), ["pieces", "flakes"])
    }

    func testEmptyInputs() {
        XCTAssertEqual(FeedSuggestions.types([], category: .food), [])
        XCTAssertEqual(FeedSuggestions.units([]), [])
    }
}
```

`AppTests/FeedSnapshotTests.swift`:
```swift
import SwiftData
import XCTest
@testable import AnimalTracker

@MainActor
final class FeedSnapshotTests: XCTestCase {
    func testFeedingSnapshotCopiesItemsInCategoryOrder() throws {
        let context = try TestSupport.container().mainContext
        let feeding = Feeding(time: Date(timeIntervalSince1970: 1_700_000_000), note: "morning")
        context.insert(feeding)
        let treat = FeedItem(category: .treat, type: "carrot", amount: 2, unit: "pieces", sortOrder: 0)
        let hay = FeedItem(category: .forage, type: "hay", amount: 2.5, unit: "flakes", sortOrder: 0)
        context.insert(treat)
        context.insert(hay)
        treat.feeding = feeding
        hay.feeding = feeding
        try context.save()

        let snapshot = FeedingSnapshot(feeding)
        XCTAssertEqual(snapshot.id, feeding.id)
        XCTAssertEqual(snapshot.time, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(snapshot.note, "morning")
        XCTAssertEqual(snapshot.items.map(\.type), ["hay", "carrot"])
        XCTAssertEqual(snapshot.items.first?.category, .forage)
        XCTAssertEqual(snapshot.items.first?.amount, 2.5)
        XCTAssertEqual(snapshot.items.first?.unit, "flakes")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/test-app.sh`
Expected: build errors, `FeedItemSnapshot`, `FeedingSnapshot`, `FeedSuggestions` not found.

- [ ] **Step 3: Write the implementation**

Append to `App/Logic/Snapshots.swift` (leave `AnimalSnapshot` and any snapshot an earlier plan added untouched; this file has no `import SwiftData`, by design):
```swift
/// A FeedItem as a value, for suggestions, row text, and export.
struct FeedItemSnapshot: Equatable, Identifiable {
    let id: UUID
    let category: FeedCategory
    let type: String
    let amount: Double
    let unit: String
    let sortOrder: Int
    let createdAt: Date

    init(id: UUID, category: FeedCategory, type: String, amount: Double, unit: String, sortOrder: Int, createdAt: Date) {
        self.id = id
        self.category = category
        self.type = type
        self.amount = amount
        self.unit = unit
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }

    init(_ item: FeedItem) {
        self.init(id: item.id, category: item.category, type: item.type, amount: item.amount,
                  unit: item.unit, sortOrder: item.sortOrder, createdAt: item.createdAt)
    }
}

/// A Feeding as a value, with its items already ordered for display.
struct FeedingSnapshot: Equatable, Identifiable {
    let id: UUID
    let time: Date
    let note: String?
    let items: [FeedItemSnapshot]

    init(id: UUID, time: Date, note: String?, items: [FeedItemSnapshot]) {
        self.id = id
        self.time = time
        self.note = note
        self.items = items
    }

    init(_ feeding: Feeding) {
        let ranks = FeedCategory.allCases
        let ordered = (feeding.items ?? []).map(FeedItemSnapshot.init).sorted { lhs, rhs in
            let left = ranks.firstIndex(of: lhs.category) ?? 0
            let right = ranks.firstIndex(of: rhs.category) ?? 0
            if left != right { return left < right }
            if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
            return lhs.createdAt < rhs.createdAt
        }
        self.init(id: feeding.id, time: feeding.time, note: feeding.note, items: ordered)
    }
}
```

`App/Logic/FeedSuggestions.swift`:
```swift
import Foundation

/// Type and unit suggestions derived from existing feed items. Pure: no SwiftData, no SwiftUI.
enum FeedSuggestions {
    /// Distinct `type` values in that category, most recent first, case-insensitive dedupe keeping the most recent casing.
    static func types(_ items: [FeedItemSnapshot], category: FeedCategory) -> [String] {
        distinct(mostRecentFirst(items.filter { $0.category == category }).map(\.type))
    }

    /// Distinct `unit` values across every category, most recent first, same dedupe.
    static func units(_ items: [FeedItemSnapshot]) -> [String] {
        distinct(mostRecentFirst(items).map(\.unit))
    }

    /// Newest createdAt first. Items sharing a timestamp keep their input order, so the result is deterministic.
    private static func mostRecentFirst(_ items: [FeedItemSnapshot]) -> [FeedItemSnapshot] {
        items.enumerated().sorted { lhs, rhs in
            if lhs.element.createdAt != rhs.element.createdAt { return lhs.element.createdAt > rhs.element.createdAt }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// Trims, drops blanks, and keeps the first spelling of each lowercased key.
    private static func distinct(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(trimmed)
        }
        return result
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/test-app.sh`
Expected: PASS, 5 new tests (19 + Plan C's tests + 8).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(feed): feeding and item snapshots, pure FeedSuggestions

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: Numeric clamps

**Files:**
- Create: `App/Logic/FeedClamps.swift`
- Test: `AppTests/FeedClampsTests.swift`

**Interfaces:**
- Consumes: nothing beyond Foundation.
- Produces: `FeedClamps.outdoorHours(_ value: Double?) -> Double?`, `FeedClamps.acres(_ value: Double?) -> Double?`, `FeedClamps.amount(_ value: Double) -> Double`, `FeedClamps.number(_ text: String) -> Double?`, `FeedClamps.maxOutdoorHours: Double`.

- [ ] **Step 1: Write the failing test**

`AppTests/FeedClampsTests.swift`:
```swift
import XCTest
@testable import AnimalTracker

final class FeedClampsTests: XCTestCase {
    func testOutdoorHoursClampedToZeroThroughTwentyFour() {
        XCTAssertNil(FeedClamps.outdoorHours(nil))
        XCTAssertNil(FeedClamps.outdoorHours(Double.nan))
        XCTAssertNil(FeedClamps.outdoorHours(Double.infinity))
        XCTAssertEqual(FeedClamps.outdoorHours(-3), 0)
        XCTAssertEqual(FeedClamps.outdoorHours(0), 0)
        XCTAssertEqual(FeedClamps.outdoorHours(7.5), 7.5)
        XCTAssertEqual(FeedClamps.outdoorHours(24), 24)
        XCTAssertEqual(FeedClamps.outdoorHours(30), 24)
        XCTAssertEqual(FeedClamps.maxOutdoorHours, 24)
    }

    func testAcresAndAmountAreNeverNegative() {
        XCTAssertNil(FeedClamps.acres(nil))
        XCTAssertNil(FeedClamps.acres(Double.nan))
        XCTAssertEqual(FeedClamps.acres(-1), 0)
        XCTAssertEqual(FeedClamps.acres(2.25), 2.25)
        XCTAssertEqual(FeedClamps.acres(400), 400)
        XCTAssertEqual(FeedClamps.amount(-4), 0)
        XCTAssertEqual(FeedClamps.amount(Double.nan), 0)
        XCTAssertEqual(FeedClamps.amount(0), 0)
        XCTAssertEqual(FeedClamps.amount(1.5), 1.5)
    }

    func testNumberParsing() {
        XCTAssertNil(FeedClamps.number(""))
        XCTAssertNil(FeedClamps.number("   "))
        XCTAssertNil(FeedClamps.number("two"))
        XCTAssertNil(FeedClamps.number("2.5kg"))
        XCTAssertEqual(FeedClamps.number(" 2.5 "), 2.5)
        XCTAssertEqual(FeedClamps.number("2,5"), 2.5)
        XCTAssertEqual(FeedClamps.number("-3"), -3)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test-app.sh`
Expected: build error, `FeedClamps` not found.

- [ ] **Step 3: Write the implementation**

`App/Logic/FeedClamps.swift`:
```swift
import Foundation

/// The spec's numeric limits: outdoor hours 0 to 24, acres and amounts >= 0. Pure: no SwiftData, no SwiftUI.
enum FeedClamps {
    static let maxOutdoorHours: Double = 24

    /// nil stays nil; NaN and infinity become nil; anything else lands in 0...24.
    static func outdoorHours(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(max(value, 0), maxOutdoorHours)
    }

    /// nil stays nil; NaN and infinity become nil; negatives become 0.
    static func acres(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return max(value, 0)
    }

    /// NaN, infinity and negatives become 0.
    static func amount(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return max(value, 0)
    }

    /// Parses a decimal text field. Accepts "." or "," as the separator. Blank or unparseable text is nil.
    /// Parsing does not clamp: pass the result through outdoorHours, acres or amount.
    static func number(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard !trimmed.isEmpty else { return nil }
        return Double(trimmed)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test-app.sh`
Expected: PASS, 3 new tests (19 + Plan C's tests + 11).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(feed): pure numeric clamps for outdoor hours, acres and amounts

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: FeedDayStore find-or-create, fetches, and day delete

**Files:**
- Create: `App/Persistence/FeedDayStore.swift`
- Test: `AppTests/FeedDayStoreTests.swift`

**Interfaces:**
- Consumes: `Animal`, `FeedDay`, `Feeding`, `FeedItem`, `FeedItemSnapshot`, `TestSupport.container()`.
- Produces: `FeedDayStore.day(for:on:calendar:context:) throws -> FeedDay`, `.existingDay(for:on:calendar:context:) throws -> FeedDay?`, `.days(for:context:) throws -> [FeedDay]` (newest first), `.itemSnapshots(for:context:) throws -> [FeedItemSnapshot]`, `.allItemSnapshots(context:) throws -> [FeedItemSnapshot]`, `.deleteDay(_:context:) throws`.

- [ ] **Step 1: Write the failing test**

`AppTests/FeedDayStoreTests.swift`:
```swift
import SwiftData
import XCTest
@testable import AnimalTracker

@MainActor
final class FeedDayStoreTests: XCTestCase {
    private func makeAnimal(_ name: String, in context: ModelContext) -> Animal {
        let animal = Animal(name: name, species: "horse")
        context.insert(animal)
        return animal
    }

    /// One day, one feeding, one item for the animal.
    private func addItem(_ type: String, to animal: Animal, context: ModelContext) throws {
        let day = try FeedDayStore.day(for: animal, on: Date(), context: context)
        let feeding = Feeding(time: Date())
        context.insert(feeding)
        feeding.day = day
        let item = FeedItem(category: .forage, type: type, amount: 1, unit: "scoop", sortOrder: 0)
        context.insert(item)
        item.feeding = feeding
        try context.save()
    }

    func testDayIsCreatedOnceAndReused() throws {
        let context = try TestSupport.container().mainContext
        let animal = makeAnimal("Juniper", in: context)
        let noon = try XCTUnwrap(Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date()))
        let first = try FeedDayStore.day(for: animal, on: noon, context: context)
        let second = try FeedDayStore.day(for: animal, on: noon.addingTimeInterval(3600), context: context)
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(try context.fetch(FetchDescriptor<FeedDay>()).count, 1)
    }

    func testDayIsStoredAtLocalStartOfDay() throws {
        let context = try TestSupport.container().mainContext
        let animal = makeAnimal("Juniper", in: context)
        let evening = try XCTUnwrap(Calendar.current.date(bySettingHour: 21, minute: 30, second: 0, of: Date()))
        let day = try FeedDayStore.day(for: animal, on: evening, context: context)
        XCTAssertEqual(day.date, Calendar.current.startOfDay(for: evening))
        XCTAssertEqual(day.animal?.id, animal.id)
    }

    func testSeparateAnimalsGetSeparateDays() throws {
        let context = try TestSupport.container().mainContext
        let horse = makeAnimal("Juniper", in: context)
        let dog = makeAnimal("Rex", in: context)
        let noon = try XCTUnwrap(Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date()))
        let horseDay = try FeedDayStore.day(for: horse, on: noon, context: context)
        let dogDay = try FeedDayStore.day(for: dog, on: noon, context: context)
        XCTAssertNotEqual(horseDay.id, dogDay.id)
        XCTAssertEqual(try FeedDayStore.days(for: horse, context: context).count, 1)
        XCTAssertEqual(try FeedDayStore.days(for: dog, context: context).count, 1)
    }

    func testDaysAreNewestFirst() throws {
        let context = try TestSupport.container().mainContext
        let animal = makeAnimal("Juniper", in: context)
        let today = Calendar.current.startOfDay(for: Date())
        let yesterday = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -1, to: today))
        _ = try FeedDayStore.day(for: animal, on: yesterday, context: context)
        _ = try FeedDayStore.day(for: animal, on: today, context: context)
        XCTAssertEqual(try FeedDayStore.days(for: animal, context: context).map(\.date), [today, yesterday])
        XCTAssertNotNil(try FeedDayStore.existingDay(for: animal, on: yesterday, context: context))
    }

    func testItemSnapshotsForOneAnimalAndForAll() throws {
        let context = try TestSupport.container().mainContext
        let horse = makeAnimal("Juniper", in: context)
        let dog = makeAnimal("Rex", in: context)
        try addItem("hay", to: horse, context: context)
        try addItem("kibble", to: dog, context: context)
        XCTAssertEqual(try FeedDayStore.itemSnapshots(for: horse, context: context).map(\.type), ["hay"])
        XCTAssertEqual(try FeedDayStore.itemSnapshots(for: dog, context: context).map(\.type), ["kibble"])
        XCTAssertEqual(Set(try FeedDayStore.allItemSnapshots(context: context).map(\.type)), ["hay", "kibble"])
    }

    func testDeleteDayRemovesFeedingsAndItems() throws {
        let context = try TestSupport.container().mainContext
        let animal = makeAnimal("Juniper", in: context)
        try addItem("hay", to: animal, context: context)
        let day = try XCTUnwrap(FeedDayStore.days(for: animal, context: context).first)
        try FeedDayStore.deleteDay(day, context: context)
        XCTAssertEqual(try context.fetch(FetchDescriptor<FeedDay>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Feeding>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<FeedItem>()).count, 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test-app.sh`
Expected: build error, `FeedDayStore` not found.

- [ ] **Step 3: Write the implementation**

`App/Persistence/FeedDayStore.swift`:
```swift
import Foundation
import SwiftData

/// Every store operation the Feed tab needs. The single creator of FeedDay rows, which is what keeps
/// one day per animal per calendar day. Animal filtering runs in Swift because #Predicate over an
/// optional to-one relationship is unreliable on iOS 17; feed data is small enough that this is free.
enum FeedDayStore {
    /// This animal's day for that calendar day, created and saved when missing.
    @discardableResult
    static func day(for animal: Animal, on date: Date, calendar: Calendar = .current, context: ModelContext) throws -> FeedDay {
        if let existing = try existingDay(for: animal, on: date, calendar: calendar, context: context) {
            return existing
        }
        let day = FeedDay(date: calendar.startOfDay(for: date), animal: animal)
        context.insert(day)
        try context.save()
        return day
    }

    /// This animal's day for that calendar day, or nil.
    static func existingDay(for animal: Animal, on date: Date, calendar: Calendar = .current, context: ModelContext) throws -> FeedDay? {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let animalID = animal.id
        let descriptor = FetchDescriptor<FeedDay>(
            predicate: #Predicate<FeedDay> { $0.date >= start && $0.date < end },
            sortBy: [SortDescriptor(\FeedDay.createdAt)]
        )
        return try context.fetch(descriptor).first { $0.animal?.id == animalID }
    }

    /// This animal's days, newest first.
    static func days(for animal: Animal, context: ModelContext) throws -> [FeedDay] {
        let animalID = animal.id
        let descriptor = FetchDescriptor<FeedDay>(sortBy: [SortDescriptor(\FeedDay.date, order: .reverse)])
        return try context.fetch(descriptor).filter { $0.animal?.id == animalID }
    }

    /// This animal's feed items, for suggestions.
    static func itemSnapshots(for animal: Animal, context: ModelContext) throws -> [FeedItemSnapshot] {
        let animalID = animal.id
        return try context.fetch(FetchDescriptor<FeedItem>())
            .filter { $0.feeding?.day?.animal?.id == animalID }
            .map(FeedItemSnapshot.init)
    }

    /// Every animal's feed items, for the suggestion fallback.
    static func allItemSnapshots(context: ModelContext) throws -> [FeedItemSnapshot] {
        try context.fetch(FetchDescriptor<FeedItem>()).map(FeedItemSnapshot.init)
    }

    /// Deletes a day; the cascade rules take its feedings and their items with it.
    static func deleteDay(_ day: FeedDay, context: ModelContext) throws {
        context.delete(day)
        try context.save()
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test-app.sh`
Expected: PASS, 6 new tests (19 + Plan C's tests + 17).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(feed): FeedDayStore find-or-create day, fetches and day delete

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: Feed tab list, Today button, and RootTabView wiring

**Files:**
- Create: `App/Logic/FeedFormatting.swift`, `App/Views/Feed/FeedTabView.swift`, `App/Views/Feed/FeedDayCardView.swift` (stub, replaced in Task 6)
- Modify: `App/RootTabView.swift` (the Feed tab line)
- Test: `AppTests/FeedFormattingTests.swift`

**Interfaces:**
- Consumes: `FeedDay`, `FeedItemSnapshot`, `FeedDayStore.day(for:on:calendar:context:)`, `FeedDayStore.deleteDay(_:context:)`, `@Environment(\.selectedAnimal)`, `Animal.tracksOutdoorTime`.
- Produces: `FeedFormatting.daySubtitle(feedingCount:outdoorHours:outdoorAreaAcres:tracksOutdoorTime:) -> String`, `FeedFormatting.itemsSummary(_ items: [FeedItemSnapshot]) -> String`, `FeedFormatting.number(_ value: Double) -> String`; `FeedTabView()`; `FeedDayCardView(day: FeedDay)`.

- [ ] **Step 1: Write the failing test**

`AppTests/FeedFormattingTests.swift`:
```swift
import XCTest
@testable import AnimalTracker

final class FeedFormattingTests: XCTestCase {
    func testDaySubtitleShowsOutdoorFiguresOnlyWhenTracked() {
        XCTAssertEqual(FeedFormatting.daySubtitle(feedingCount: 2, outdoorHours: 4.5, outdoorAreaAcres: 2, tracksOutdoorTime: true),
                       "2 feedings, 4.5 h out, 2 acres")
        XCTAssertEqual(FeedFormatting.daySubtitle(feedingCount: 1, outdoorHours: 4.5, outdoorAreaAcres: 2, tracksOutdoorTime: false),
                       "1 feeding")
        XCTAssertEqual(FeedFormatting.daySubtitle(feedingCount: 0, outdoorHours: nil, outdoorAreaAcres: nil, tracksOutdoorTime: true),
                       "0 feedings")
        XCTAssertEqual(FeedFormatting.daySubtitle(feedingCount: 3, outdoorHours: nil, outdoorAreaAcres: 1.25, tracksOutdoorTime: true),
                       "3 feedings, 1.25 acres")
    }

    func testItemsSummary() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let items = [
            FeedItemSnapshot(id: UUID(), category: .forage, type: "hay", amount: 2, unit: "flakes", sortOrder: 0, createdAt: now),
            FeedItemSnapshot(id: UUID(), category: .food, type: "Purina Senior", amount: 1.5, unit: "scoop", sortOrder: 0, createdAt: now),
            FeedItemSnapshot(id: UUID(), category: .treat, type: "carrot", amount: 0, unit: "", sortOrder: 0, createdAt: now),
        ]
        XCTAssertEqual(FeedFormatting.itemsSummary(items), "hay 2 flakes, Purina Senior 1.5 scoop, carrot")
        XCTAssertEqual(FeedFormatting.itemsSummary([]), "")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test-app.sh`
Expected: build error, `FeedFormatting` not found.

- [ ] **Step 3: Write the implementation**

`App/Logic/FeedFormatting.swift`:
```swift
import Foundation

/// Row text for the Feed tab and day card. Pure: no SwiftData, no SwiftUI.
enum FeedFormatting {
    /// "2 feedings, 4.5 h out, 2 acres". Outdoor figures appear only for animals that track outdoor time.
    static func daySubtitle(feedingCount: Int, outdoorHours: Double?, outdoorAreaAcres: Double?, tracksOutdoorTime: Bool) -> String {
        var parts = ["\(feedingCount) \(feedingCount == 1 ? "feeding" : "feedings")"]
        if tracksOutdoorTime {
            if let hours = outdoorHours { parts.append("\(number(hours)) h out") }
            if let acres = outdoorAreaAcres { parts.append("\(number(acres)) acres") }
        }
        return parts.joined(separator: ", ")
    }

    /// "hay 2 flakes, Purina Senior 1.5 scoop". A zero amount prints the type alone.
    static func itemsSummary(_ items: [FeedItemSnapshot]) -> String {
        items.map { item in
            let type = item.type.trimmingCharacters(in: .whitespaces)
            let amount = item.amount > 0 ? number(item.amount) : ""
            let unit = amount.isEmpty ? "" : item.unit.trimmingCharacters(in: .whitespaces)
            return [type, amount, unit].filter { !$0.isEmpty }.joined(separator: " ")
        }
        .filter { !$0.isEmpty }
        .joined(separator: ", ")
    }

    /// 2.0 reads "2", 1.5 reads "1.5", 1.25 reads "1.25".
    static func number(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if value == value.rounded() && abs(value) < 1e9 { return String(Int(value)) }
        return String(format: "%.2f", value).replacingOccurrences(of: "0$", with: "", options: .regularExpression)
    }
}
```

`App/Views/Feed/FeedTabView.swift`:
```swift
import SwiftData
import SwiftUI

/// Feed tab root. RootTabView owns the NavigationStack and the shared toolbar, so this view adds
/// neither; it pushes the day card with navigationDestination(item:) so the Today button can navigate.
struct FeedTabView: View {
    @Environment(\.selectedAnimal) private var animal
    @Environment(\.modelContext) private var context
    @Query(sort: \FeedDay.date, order: .reverse) private var allDays: [FeedDay]
    @State private var openDay: FeedDay?
    @State private var dayPendingDelete: FeedDay?
    @State private var message: String?

    private var days: [FeedDay] {
        guard let animal else { return [] }
        return allDays.filter { $0.animal?.id == animal.id }
    }

    var body: some View {
        Group {
            if let animal {
                list(for: animal)
            } else {
                ContentUnavailableView("No animal selected", systemImage: "pawprint",
                                       description: Text("Add an animal in Manage Animals to log feed."))
            }
        }
        .navigationDestination(item: $openDay) { day in FeedDayCardView(day: day) }
        .confirmationDialog("Delete this day?",
                            isPresented: Binding(get: { dayPendingDelete != nil },
                                                 set: { if !$0 { dayPendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete day and its feedings", role: .destructive) { deletePendingDay() }
            Button("Cancel", role: .cancel) { dayPendingDelete = nil }
        } message: {
            Text("This removes the day, its feedings, and their items.")
        }
        .alert("Feed", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    private func list(for animal: Animal) -> some View {
        List {
            Section {
                Button { openToday(for: animal) } label: { Label("Today", systemImage: "calendar") }
            }
            Section("Days") {
                if days.isEmpty {
                    Text("No feed days yet. Tap Today to start one.").foregroundStyle(.secondary)
                }
                ForEach(days) { day in
                    Button { openDay = day } label: { row(day, animal: animal) }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button("Delete", role: .destructive) { dayPendingDelete = day }
                        }
                }
            }
        }
    }

    private func row(_ day: FeedDay, animal: Animal) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(day.date.formatted(date: .abbreviated, time: .omitted)).font(.headline)
            Text(FeedFormatting.daySubtitle(feedingCount: day.feedings?.count ?? 0,
                                            outdoorHours: day.outdoorHours,
                                            outdoorAreaAcres: day.outdoorAreaAcres,
                                            tracksOutdoorTime: animal.tracksOutdoorTime))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func openToday(for animal: Animal) {
        do {
            openDay = try FeedDayStore.day(for: animal, on: Date(), context: context)
        } catch {
            message = "Could not open today: \(error)"
        }
    }

    private func deletePendingDay() {
        guard let day = dayPendingDelete else { return }
        dayPendingDelete = nil
        do {
            try FeedDayStore.deleteDay(day, context: context)
        } catch {
            message = "Could not delete the day: \(error)"
        }
    }
}
```

`App/Views/Feed/FeedDayCardView.swift` (stub so this task compiles; Task 6 replaces the whole file):
```swift
import SwiftUI

struct FeedDayCardView: View {
    let day: FeedDay

    var body: some View {
        Text(day.date.formatted(date: .long, time: .omitted))
            .navigationTitle("Day")
    }
}
```

In `App/RootTabView.swift`, replace the line
```swift
            tab("Feed", "leaf") { Text("Feed") }
```
with
```swift
            tab("Feed", "leaf") { FeedTabView() }
```
Leave the other four tab lines exactly as they are.

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test-app.sh`
Expected: PASS, 2 new tests (19 + Plan C's tests + 19).

- [ ] **Step 5: Look at it**

Run: `scripts/run-sim.sh`, then read `build/screenshot.png`. With no animals the first-run Manage Animals cover appears: add a horse with outdoor tracking on, then open the Feed tab and run `scripts/run-sim.sh` again. Expected: an empty "Days" section with "No feed days yet. Tap Today to start one." and a Today row above it. Tap Today and confirm a day row appears reading "0 feedings".

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(feed): Feed tab day list with Today button and delete confirmation

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: Day card with outdoor fields, note, and feedings

**Files:**
- Modify: `App/Persistence/FeedDayStore.swift` (add `updateDay` and `deleteFeeding`)
- Modify: `App/Views/Feed/FeedDayCardView.swift` (replace the stub)
- Create: `App/Views/Feed/FeedingEditorView.swift` (stub, replaced in Task 7)
- Test: `AppTests/FeedDayStoreTests.swift` (append two tests)

**Interfaces:**
- Consumes: `FeedClamps`, `FeedFormatting`, `FeedingSnapshot`, `FeedDayStore.day(for:on:calendar:context:)`.
- Produces: `FeedDayStore.updateDay(_:outdoorHoursText:outdoorAcresText:note:context:) throws`, `FeedDayStore.deleteFeeding(_:context:) throws`; `FeedDayCardView(day: FeedDay)`; `FeedingEditorView(day: FeedDay, feeding: Feeding?)`.

- [ ] **Step 1: Write the failing tests**

Append these two methods inside `final class FeedDayStoreTests` in `AppTests/FeedDayStoreTests.swift`:
```swift
    func testUpdateDayClampsFieldsAndBlanksTheNote() throws {
        let context = try TestSupport.container().mainContext
        let animal = makeAnimal("Juniper", in: context)
        let day = try FeedDayStore.day(for: animal, on: Date(), context: context)

        try FeedDayStore.updateDay(day, outdoorHoursText: "30", outdoorAcresText: "-2", note: "  windy  ", context: context)
        XCTAssertEqual(day.outdoorHours, 24)
        XCTAssertEqual(day.outdoorAreaAcres, 0)
        XCTAssertEqual(day.note, "windy")

        try FeedDayStore.updateDay(day, outdoorHoursText: "7,5", outdoorAcresText: "2.25", note: "   ", context: context)
        XCTAssertEqual(day.outdoorHours, 7.5)
        XCTAssertEqual(day.outdoorAreaAcres, 2.25)
        XCTAssertNil(day.note)

        try FeedDayStore.updateDay(day, outdoorHoursText: "", outdoorAcresText: "nonsense", note: "", context: context)
        XCTAssertNil(day.outdoorHours)
        XCTAssertNil(day.outdoorAreaAcres)
    }

    func testDeleteFeedingRemovesItsItemsAndLeavesTheDay() throws {
        let context = try TestSupport.container().mainContext
        let animal = makeAnimal("Juniper", in: context)
        try addItem("hay", to: animal, context: context)
        let day = try XCTUnwrap(FeedDayStore.days(for: animal, context: context).first)
        let feeding = try XCTUnwrap(day.feedings?.first)
        try FeedDayStore.deleteFeeding(feeding, context: context)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Feeding>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<FeedItem>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<FeedDay>()).count, 1)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/test-app.sh`
Expected: build errors, `updateDay` and `deleteFeeding` are not members of `FeedDayStore`.

- [ ] **Step 3: Write the implementation**

Append these two methods inside `enum FeedDayStore` in `App/Persistence/FeedDayStore.swift`:
```swift
    /// Writes the day card's text fields with the spec's clamps: hours 0 to 24, acres >= 0, blank note becomes nil.
    static func updateDay(_ day: FeedDay, outdoorHoursText: String, outdoorAcresText: String, note: String, context: ModelContext) throws {
        day.outdoorHours = FeedClamps.outdoorHours(FeedClamps.number(outdoorHoursText))
        day.outdoorAreaAcres = FeedClamps.acres(FeedClamps.number(outdoorAcresText))
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        day.note = trimmed.isEmpty ? nil : trimmed
        try context.save()
    }

    /// Deletes a feeding; the cascade rule takes its items with it.
    static func deleteFeeding(_ feeding: Feeding, context: ModelContext) throws {
        context.delete(feeding)
        try context.save()
    }
```

`App/Views/Feed/FeedDayCardView.swift` (replace the whole stub file):
```swift
import SwiftData
import SwiftUI

/// One feed day: outdoor figures when the animal tracks outdoor time, a note, then feedings in time order.
/// Fields write through to the store as they change, clamped on every write.
struct FeedDayCardView: View {
    let day: FeedDay

    @Environment(\.selectedAnimal) private var animal
    @Environment(\.modelContext) private var context
    @State private var hoursText = ""
    @State private var acresText = ""
    @State private var noteText = ""
    @State private var editingFeeding: Feeding?
    @State private var isAddingFeeding = false
    @State private var message: String?
    @State private var loaded = false

    private var feedings: [Feeding] {
        (day.feedings ?? []).sorted { $0.time < $1.time }
    }

    var body: some View {
        Form {
            if animal?.tracksOutdoorTime ?? false {
                Section("Outdoor") {
                    LabeledContent("Hours") {
                        TextField("0 to 24", text: $hoursText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Area (acres)") {
                        TextField("acres", text: $acresText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            Section("Note") {
                TextField("Note", text: $noteText, axis: .vertical).lineLimit(1...4)
            }
            Section("Feedings") {
                if feedings.isEmpty {
                    Text("No feedings yet.").foregroundStyle(.secondary)
                }
                ForEach(feedings) { feeding in
                    Button { editingFeeding = feeding } label: { feedingRow(feeding) }
                        .buttonStyle(.plain)
                }
                .onDelete(perform: deleteFeedings)
                Button { isAddingFeeding = true } label: { Label("Add Feeding", systemImage: "plus") }
            }
        }
        .navigationTitle(day.date.formatted(date: .abbreviated, time: .omitted))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadFields)
        .onChange(of: hoursText) { _, _ in commitFields() }
        .onChange(of: acresText) { _, _ in commitFields() }
        .onChange(of: noteText) { _, _ in commitFields() }
        .sheet(item: $editingFeeding) { feeding in
            NavigationStack { FeedingEditorView(day: day, feeding: feeding) }
        }
        .sheet(isPresented: $isAddingFeeding) {
            NavigationStack { FeedingEditorView(day: day, feeding: nil) }
        }
        .alert("Feed", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    private func feedingRow(_ feeding: Feeding) -> some View {
        let snapshot = FeedingSnapshot(feeding)
        let summary = FeedFormatting.itemsSummary(snapshot.items)
        return VStack(alignment: .leading, spacing: 2) {
            Text(snapshot.time.formatted(date: .omitted, time: .shortened)).font(.headline)
            Text(summary.isEmpty ? "No items" : summary).font(.subheadline).foregroundStyle(.secondary)
            if let note = snapshot.note, !note.isEmpty {
                Text(note).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// Text fields start from the stored values, once.
    private func loadFields() {
        guard !loaded else { return }
        loaded = true
        hoursText = day.outdoorHours.map(FeedFormatting.number) ?? ""
        acresText = day.outdoorAreaAcres.map(FeedFormatting.number) ?? ""
        noteText = day.note ?? ""
    }

    private func commitFields() {
        guard loaded else { return }
        do {
            try FeedDayStore.updateDay(day, outdoorHoursText: hoursText, outdoorAcresText: acresText,
                                       note: noteText, context: context)
        } catch {
            message = "Could not save the day: \(error)"
        }
    }

    private func deleteFeedings(_ offsets: IndexSet) {
        let targets = offsets.map { feedings[$0] }
        do {
            for feeding in targets { try FeedDayStore.deleteFeeding(feeding, context: context) }
        } catch {
            message = "Could not delete the feeding: \(error)"
        }
    }
}
```

`App/Views/Feed/FeedingEditorView.swift` (stub with the final signature; Task 7 replaces the whole file):
```swift
import SwiftUI

struct FeedingEditorView: View {
    let day: FeedDay
    var feeding: Feeding?

    var body: some View {
        Text("Feeding editor")
            .navigationTitle(feeding == nil ? "New Feeding" : "Edit Feeding")
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/test-app.sh`
Expected: PASS, 2 new tests (19 + Plan C's tests + 21).

- [ ] **Step 5: Look at it**

Run: `scripts/run-sim.sh`, then read `build/screenshot.png`. On the horse's Feed tab, tap Today: the card shows Outdoor (Hours, Area), Note, and an empty Feedings section with Add Feeding. Type 4.5 into Hours, go back, and confirm the day row reads "0 feedings, 4.5 h out". Then switch to an animal with outdoor tracking off (add a dog if there is none) and confirm its day card has no Outdoor section.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(feed): day card with clamped outdoor fields, note and feeding list

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: Feeding editor with drafts, four sections, and suggestion chips

**Files:**
- Create: `App/Logic/FeedItemDraft.swift`, `App/Views/Feed/SuggestionChipsView.swift`
- Modify: `App/Persistence/FeedDayStore.swift` (add `saveFeeding`)
- Modify: `App/Views/Feed/FeedingEditorView.swift` (replace the stub)
- Test: `AppTests/FeedingSaveTests.swift`

**Interfaces:**
- Consumes: `FeedSuggestions.types(_:category:)`, `FeedSuggestions.units(_:)`, `FeedClamps.number(_:)`, `FeedClamps.amount(_:)`, `FeedFormatting.number(_:)`, `FeedingSnapshot`, `FeedItemSnapshot`, `FeedDayStore.itemSnapshots(for:context:)`, `FeedDayStore.allItemSnapshots(context:)`.
- Produces: `FeedItemDraft(category:type:amountText:unit:existingID:)` plus `init(_ snapshot: FeedItemSnapshot)` and `static func copy(of: FeedItemSnapshot) -> FeedItemDraft`; `FeedDayStore.saveFeeding(day:feeding:time:note:drafts:context:) throws -> Feeding`; `SuggestionChipsView(suggestions:limit:onSelect:)`; `FeedingEditorView(day:feeding:)` with `static func defaultTime(for:now:calendar:) -> Date`; `FeedCategory.sectionTitle`.

- [ ] **Step 1: Write the failing test**

`AppTests/FeedingSaveTests.swift`:
```swift
import SwiftData
import XCTest
@testable import AnimalTracker

@MainActor
final class FeedingSaveTests: XCTestCase {
    private func makeDay() throws -> (ModelContext, FeedDay) {
        let context = try TestSupport.container().mainContext
        let animal = Animal(name: "Juniper", species: "horse")
        context.insert(animal)
        let day = try FeedDayStore.day(for: animal, on: Date(), context: context)
        return (context, day)
    }

    func testSaveCreatesFeedingWithItemsNumberedPerCategory() throws {
        let (context, day) = try makeDay()
        let drafts = [FeedItemDraft(category: .forage, type: "hay", amountText: "2", unit: "flakes"),
                      FeedItemDraft(category: .forage, type: "haylage", amountText: "1", unit: "kg"),
                      FeedItemDraft(category: .food, type: "Purina Senior", amountText: "1.5", unit: "scoop")]
        let time = Date(timeIntervalSince1970: 1_700_000_000)
        let feeding = try FeedDayStore.saveFeeding(day: day, feeding: nil, time: time, note: "   ", drafts: drafts, context: context)

        XCTAssertEqual(feeding.time, time)
        XCTAssertNil(feeding.note)
        XCTAssertEqual(feeding.day?.id, day.id)
        XCTAssertEqual(day.feedings?.count, 1)
        let snapshot = FeedingSnapshot(feeding)
        XCTAssertEqual(snapshot.items.map(\.type), ["hay", "haylage", "Purina Senior"])
        XCTAssertEqual(snapshot.items.map(\.sortOrder), [0, 1, 0])
        XCTAssertEqual(snapshot.items.map(\.amount), [2, 1, 1.5])
        XCTAssertEqual(snapshot.items.map(\.unit), ["flakes", "kg", "scoop"])
    }

    func testSaveUpdatesRenamesAndDeletesInPlace() throws {
        let (context, day) = try makeDay()
        let feeding = try FeedDayStore.saveFeeding(
            day: day, feeding: nil, time: Date(timeIntervalSince1970: 1_700_000_000), note: "morning",
            drafts: [FeedItemDraft(category: .forage, type: "hay", amountText: "2", unit: "flakes"),
                     FeedItemDraft(category: .treat, type: "carrot", amountText: "3", unit: "pieces")],
            context: context)
        XCTAssertEqual(feeding.note, "morning")

        var drafts = FeedingSnapshot(feeding).items.map(FeedItemDraft.init)
        drafts[0].type = "haylage"
        drafts.removeLast()
        drafts.append(FeedItemDraft(category: .supplement, type: "MSM", amountText: "10", unit: "g"))
        _ = try FeedDayStore.saveFeeding(day: day, feeding: feeding, time: feeding.time, note: "", drafts: drafts, context: context)

        let snapshot = FeedingSnapshot(feeding)
        XCTAssertEqual(snapshot.items.map(\.type), ["haylage", "MSM"])
        XCTAssertNil(snapshot.note)
        XCTAssertEqual(try context.fetch(FetchDescriptor<FeedItem>()).count, 2)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Feeding>()).count, 1)
    }

    func testSaveTrimsClampsAndDropsRowsWithoutAType() throws {
        let (context, day) = try makeDay()
        let drafts = [FeedItemDraft(category: .forage, type: "  hay  ", amountText: "-2", unit: "  flakes "),
                      FeedItemDraft(category: .food, type: "   ", amountText: "5", unit: "cup"),
                      FeedItemDraft(category: .treat, type: "carrot", amountText: "abc", unit: "")]
        let feeding = try FeedDayStore.saveFeeding(day: day, feeding: nil, time: Date(), note: "", drafts: drafts, context: context)

        let snapshot = FeedingSnapshot(feeding)
        XCTAssertEqual(snapshot.items.map(\.type), ["hay", "carrot"])
        XCTAssertEqual(snapshot.items.map(\.amount), [0, 0])
        XCTAssertEqual(snapshot.items.first?.unit, "flakes")
        XCTAssertEqual(try context.fetch(FetchDescriptor<FeedItem>()).count, 2)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test-app.sh`
Expected: build errors, `FeedItemDraft` not found and `saveFeeding` is not a member of `FeedDayStore`.

- [ ] **Step 3: Write the implementation**

`App/Logic/FeedItemDraft.swift`:
```swift
import Foundation

/// One editable row of the feeding editor. The editor holds drafts and writes only on Save, which is
/// what lets Cancel undo "Copy last feeding". Pure: no SwiftData, no SwiftUI.
struct FeedItemDraft: Identifiable, Equatable {
    var id: UUID = UUID()
    var category: FeedCategory
    var type: String
    var amountText: String
    var unit: String
    /// The FeedItem this row edits, or nil for a row added in this editing session.
    var existingID: UUID?

    init(category: FeedCategory, type: String = "", amountText: String = "", unit: String = "", existingID: UUID? = nil) {
        self.category = category
        self.type = type
        self.amountText = amountText
        self.unit = unit
        self.existingID = existingID
    }

    /// A row that edits an existing item.
    init(_ snapshot: FeedItemSnapshot) {
        self.init(category: snapshot.category,
                  type: snapshot.type,
                  amountText: snapshot.amount > 0 ? FeedFormatting.number(snapshot.amount) : "",
                  unit: snapshot.unit,
                  existingID: snapshot.id)
    }

    /// A row copied from another feeding: same values, but a new item on save.
    static func copy(of snapshot: FeedItemSnapshot) -> FeedItemDraft {
        FeedItemDraft(category: snapshot.category,
                      type: snapshot.type,
                      amountText: snapshot.amount > 0 ? FeedFormatting.number(snapshot.amount) : "",
                      unit: snapshot.unit,
                      existingID: nil)
    }
}
```

Append this method inside `enum FeedDayStore` in `App/Persistence/FeedDayStore.swift`:
```swift
    /// Writes the editor's drafts. Creates the feeding when `feeding` is nil, updates matched items,
    /// inserts new ones, deletes items whose row is gone, and drops rows with a blank type.
    /// sortOrder counts from 0 within each category.
    @discardableResult
    static func saveFeeding(day: FeedDay, feeding: Feeding?, time: Date, note: String,
                            drafts: [FeedItemDraft], context: ModelContext) throws -> Feeding {
        let target: Feeding
        if let feeding {
            target = feeding
        } else {
            let created = Feeding(time: time)
            context.insert(created)
            created.day = day
            target = created
        }
        target.time = time
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        target.note = trimmedNote.isEmpty ? nil : trimmedNote
        if target.day == nil { target.day = day }

        let usable = drafts.filter { !$0.type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let keptIDs = Set(usable.compactMap(\.existingID))
        for item in target.items ?? [] where !keptIDs.contains(item.id) {
            context.delete(item)
        }

        var counters: [FeedCategory: Int] = [:]
        for draft in usable {
            let index = counters[draft.category] ?? 0
            counters[draft.category] = index + 1

            let item: FeedItem
            if let existingID = draft.existingID, let match = (target.items ?? []).first(where: { $0.id == existingID }) {
                item = match
            } else {
                let created = FeedItem(category: draft.category)
                context.insert(created)
                created.feeding = target
                item = created
            }
            item.category = draft.category
            item.type = draft.type.trimmingCharacters(in: .whitespacesAndNewlines)
            item.amount = FeedClamps.amount(FeedClamps.number(draft.amountText) ?? 0)
            item.unit = draft.unit.trimmingCharacters(in: .whitespacesAndNewlines)
            item.sortOrder = index
        }
        try context.save()
        return target
    }
```

`App/Views/Feed/SuggestionChipsView.swift`:
```swift
import SwiftUI

/// A horizontal row of tappable suggestions under a text field. Shows nothing when there is nothing to suggest.
struct SuggestionChipsView: View {
    let suggestions: [String]
    var limit = 8
    let onSelect: (String) -> Void

    var body: some View {
        if suggestions.isEmpty {
            EmptyView()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(suggestions.prefix(limit)), id: \.self) { suggestion in
                        Button(suggestion) { onSelect(suggestion) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .font(.footnote)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}
```

`App/Views/Feed/FeedingEditorView.swift` (replace the whole stub file):
```swift
import SwiftData
import SwiftUI

extension FeedCategory {
    /// Section titles from the spec's Feed tab.
    var sectionTitle: String {
        switch self {
        case .forage: return "Forage"
        case .food: return "Food"
        case .supplement: return "Supplements"
        case .treat: return "Treats"
        }
    }
}

/// Edits one feeding on draft values. Nothing reaches the store until Save, so Cancel throws away
/// every change, including a "Copy last feeding" prefill.
struct FeedingEditorView: View {
    let day: FeedDay
    var feeding: Feeding?

    @Environment(\.selectedAnimal) private var animal
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var time = Date()
    @State private var note = ""
    @State private var drafts: [FeedItemDraft] = []
    @State private var animalItems: [FeedItemSnapshot] = []
    @State private var allItems: [FeedItemSnapshot] = []
    @State private var message: String?
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                DatePicker("Time", selection: $time, displayedComponents: [.hourAndMinute])
            }
            ForEach(FeedCategory.allCases, id: \.self) { category in
                Section(category.sectionTitle) {
                    ForEach(rows(in: category)) { draft in
                        itemRow(draft)
                    }
                    .onDelete { offsets in delete(offsets, in: category) }
                    Button {
                        drafts.append(FeedItemDraft(category: category))
                    } label: {
                        Label("Add item", systemImage: "plus")
                    }
                }
            }
            Section("Note") {
                TextField("Note", text: $note, axis: .vertical).lineLimit(1...4)
            }
        }
        .navigationTitle(feeding == nil ? "New Feeding" : "Edit Feeding")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
        }
        .onAppear(perform: load)
        .alert("Feed", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    private func rows(in category: FeedCategory) -> [FeedItemDraft] {
        drafts.filter { $0.category == category }
    }

    private func itemRow(_ draft: FeedItemDraft) -> some View {
        let row = binding(for: draft)
        return VStack(alignment: .leading, spacing: 6) {
            TextField("Type (hay, kibble, MSM)", text: row.type)
            SuggestionChipsView(suggestions: typeSuggestions(for: draft.category)) { row.wrappedValue.type = $0 }
            HStack {
                TextField("Amount", text: row.amountText)
                    .keyboardType(.decimalPad)
                    .frame(maxWidth: 110)
                TextField("Unit (flakes, lb, scoop)", text: row.unit)
            }
            SuggestionChipsView(suggestions: unitSuggestions()) { row.wrappedValue.unit = $0 }
        }
    }

    /// Edits the draft in place by id, so rows keep working after inserts and deletes.
    private func binding(for draft: FeedItemDraft) -> Binding<FeedItemDraft> {
        Binding(
            get: { drafts.first { $0.id == draft.id } ?? draft },
            set: { newValue in
                if let index = drafts.firstIndex(where: { $0.id == newValue.id }) { drafts[index] = newValue }
            }
        )
    }

    private func delete(_ offsets: IndexSet, in category: FeedCategory) {
        let rows = rows(in: category)
        let ids = Set(offsets.map { rows[$0].id })
        drafts.removeAll { ids.contains($0.id) }
    }

    /// The selected animal's types for that category, falling back to every animal's.
    private func typeSuggestions(for category: FeedCategory) -> [String] {
        let own = FeedSuggestions.types(animalItems, category: category)
        return own.isEmpty ? FeedSuggestions.types(allItems, category: category) : own
    }

    /// The selected animal's units, falling back to every animal's.
    private func unitSuggestions() -> [String] {
        let own = FeedSuggestions.units(animalItems)
        return own.isEmpty ? FeedSuggestions.units(allItems) : own
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let feeding {
            let snapshot = FeedingSnapshot(feeding)
            time = snapshot.time
            note = snapshot.note ?? ""
            drafts = snapshot.items.map(FeedItemDraft.init)
        } else {
            time = Self.defaultTime(for: day.date)
            note = ""
            drafts = []
        }
        do {
            if let animal { animalItems = try FeedDayStore.itemSnapshots(for: animal, context: context) }
            allItems = try FeedDayStore.allItemSnapshots(context: context)
        } catch {
            message = "Could not load suggestions: \(error)"
        }
    }

    /// The current clock time on the day being edited, so a feeding added to an older day is not dated today.
    static func defaultTime(for dayDate: Date, now: Date = Date(), calendar: Calendar = .current) -> Date {
        let parts = calendar.dateComponents([.hour, .minute], from: now)
        return calendar.date(bySettingHour: parts.hour ?? 12, minute: parts.minute ?? 0, second: 0, of: dayDate) ?? dayDate
    }

    private func save() {
        do {
            try FeedDayStore.saveFeeding(day: day, feeding: feeding, time: time, note: note, drafts: drafts, context: context)
            dismiss()
        } catch {
            message = "Could not save the feeding: \(error)"
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test-app.sh`
Expected: PASS, 3 new tests (19 + Plan C's tests + 24).

- [ ] **Step 5: Look at it**

Run: `scripts/run-sim.sh`, then read `build/screenshot.png`. On the horse's day card tap Add Feeding: the editor shows Time, then Forage, Food, Supplements and Treats, each with an Add item row, then Note. Add a forage item "hay, 2 flakes" and a food item "Purina Senior, 1.5 scoop", Save, and confirm the day card row reads "hay 2 flakes, Purina Senior 1.5 scoop". Open the editor again and confirm the type field now offers a "hay" chip, and that swiping an item row deletes it. Open a new feeding, type a stray value, tap Cancel, and confirm nothing changed on the card.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(feed): feeding editor on draft values with suggestion chips and per-category sections

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: Copy last feeding

**Files:**
- Modify: `App/Persistence/FeedDayStore.swift` (add `mostRecentFeeding`)
- Modify: `App/Views/Feed/FeedingEditorView.swift` (add the button and its action)
- Test: `AppTests/FeedCopyLastTests.swift`

**Interfaces:**
- Consumes: `FeedDayStore.saveFeeding(day:feeding:time:note:drafts:context:)`, `FeedItemDraft.copy(of:)`, `FeedingSnapshot`.
- Produces: `FeedDayStore.mostRecentFeeding(for:excluding:context:) throws -> FeedingSnapshot?`.

- [ ] **Step 1: Write the failing test**

`AppTests/FeedCopyLastTests.swift`:
```swift
import SwiftData
import XCTest
@testable import AnimalTracker

@MainActor
final class FeedCopyLastTests: XCTestCase {
    func testMostRecentFeedingSkipsTheOneBeingEdited() throws {
        let context = try TestSupport.container().mainContext
        let animal = Animal(name: "Juniper", species: "horse")
        context.insert(animal)
        let other = Animal(name: "Rex", species: "dog")
        context.insert(other)
        let day = try FeedDayStore.day(for: animal, on: Date(), context: context)
        let otherDay = try FeedDayStore.day(for: other, on: Date(), context: context)

        let morning = try FeedDayStore.saveFeeding(
            day: day, feeding: nil, time: Date(timeIntervalSince1970: 1_700_000_000), note: "",
            drafts: [FeedItemDraft(category: .forage, type: "hay", amountText: "2", unit: "flakes")], context: context)
        let evening = try FeedDayStore.saveFeeding(
            day: day, feeding: nil, time: Date(timeIntervalSince1970: 1_700_040_000), note: "",
            drafts: [FeedItemDraft(category: .food, type: "kibble", amountText: "1", unit: "cup")], context: context)
        _ = try FeedDayStore.saveFeeding(
            day: otherDay, feeding: nil, time: Date(timeIntervalSince1970: 1_700_080_000), note: "",
            drafts: [FeedItemDraft(category: .food, type: "dog food", amountText: "1", unit: "cup")], context: context)

        XCTAssertEqual(try FeedDayStore.mostRecentFeeding(for: animal, excluding: nil, context: context)?.id, evening.id)
        let previous = try FeedDayStore.mostRecentFeeding(for: animal, excluding: evening.id, context: context)
        XCTAssertEqual(previous?.id, morning.id)
        XCTAssertEqual(previous?.items.map(\.type), ["hay"])
        XCTAssertEqual(previous?.items.map(\.unit), ["flakes"])
    }

    func testMostRecentFeedingIsNilWithoutFeedings() throws {
        let context = try TestSupport.container().mainContext
        let animal = Animal(name: "Rex", species: "dog")
        context.insert(animal)
        try context.save()
        XCTAssertNil(try FeedDayStore.mostRecentFeeding(for: animal, excluding: nil, context: context))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test-app.sh`
Expected: build error, `mostRecentFeeding` is not a member of `FeedDayStore`.

- [ ] **Step 3: Write the implementation**

Append this method inside `enum FeedDayStore` in `App/Persistence/FeedDayStore.swift`:
```swift
    /// The animal's latest feeding by time, ignoring one id (the feeding being edited).
    static func mostRecentFeeding(for animal: Animal, excluding excludedID: UUID?, context: ModelContext) throws -> FeedingSnapshot? {
        let animalID = animal.id
        let descriptor = FetchDescriptor<Feeding>(sortBy: [SortDescriptor(\Feeding.time, order: .reverse)])
        let match = try context.fetch(descriptor).first { $0.day?.animal?.id == animalID && $0.id != excludedID }
        return match.map(FeedingSnapshot.init)
    }
```

In `App/Views/Feed/FeedingEditorView.swift`, replace the first section
```swift
            Section {
                DatePicker("Time", selection: $time, displayedComponents: [.hourAndMinute])
            }
```
with
```swift
            Section {
                DatePicker("Time", selection: $time, displayedComponents: [.hourAndMinute])
                Button { copyLastFeeding() } label: { Label("Copy last feeding", systemImage: "doc.on.doc") }
            } footer: {
                Text("Copies the items of this animal's most recent feeding. Cancel undoes it.")
            }
```
and add this method to the same view, next to `save()`:
```swift
    /// Replaces the item rows with copies of the animal's most recent other feeding. Nothing is written
    /// until Save, so Cancel undoes it.
    private func copyLastFeeding() {
        guard let animal else {
            message = "Select an animal first."
            return
        }
        do {
            guard let last = try FeedDayStore.mostRecentFeeding(for: animal, excluding: feeding?.id, context: context) else {
                message = "There is no earlier feeding to copy."
                return
            }
            drafts = last.items.map(FeedItemDraft.copy(of:))
        } catch {
            message = "Could not read the last feeding: \(error)"
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test-app.sh`
Expected: PASS, 2 new tests (19 + Plan C's tests + 26).

- [ ] **Step 5: Look at it**

Run: `scripts/run-sim.sh`, then read `build/screenshot.png`. On the horse's day card add a second feeding, tap "Copy last feeding", and confirm the first feeding's items appear in their sections. Tap Cancel and confirm the day card still shows one feeding. Repeat, tap Save, and confirm the second feeding appears in time order with the same items. Swipe a feeding row to delete it, then swipe a day row on the Feed tab and confirm the confirmation dialog appears before the day goes.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(feed): copy last feeding into the editor drafts

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```
