# AnimalTracker shared model contract

Binding names for every SwiftData model and field, so the per-subsystem plans (B voice, C buttons, D feed, E poop + health, F oral check-in, G export/import) agree without talking to each other. Derived from `2026-09-16-animal-tracker-design.md`. Plan A already defines `Animal`, the enums in `App/Models/Enums.swift`, `PersistenceController`, `AnimalDeletionPolicy`, `Seeds`, `MediaStore`, `KeychainStore`, `RootTabView`, `SettingsView`.

## Conventions

- Every model: `var id: UUID = UUID()`, `var createdAt: Date = Date()`. Every stored property has a default or is optional. Relationships are optional. One side of each relationship declares `@Relationship(deleteRule:inverse:)`; the other side is a plain optional.
- Enum-backed fields are stored as `<name>Raw: String` with a computed `<name>` accessor, e.g. `var kindRaw: String = PressKind.spontaneous.rawValue` and `var kind: PressKind { get { PressKind(rawValue: kindRaw) ?? .spontaneous } set { kindRaw = newValue.rawValue } }`.
- Every domain record has `var animal: Animal?` (no inverse array on `Animal`). Record counts for deletion come from fetch predicates on each domain's model, registered in `AnimalDeletionPolicy.recordCounts`.
- Registration points each plan must touch: append model types to `PersistenceController.modelTypes`; append seed closures to `Seeds.all`; add one entry to `AnimalDeletionPolicy.recordCounts`; replace the tab placeholder line in `RootTabView`; replace the matching `SettingsPlaceholderRow` in `SettingsView`; add snapshot structs to `App/Logic/Snapshots.swift`.
- Media filenames are relative to `Documents/Media/` and go through `MediaStore`.

## Models

```swift
@Model final class AACButton {
    id, createdAt
    var label: String = ""
    var colorHex: String = ColorPalette.defaultHex
    var sortOrder: Int = 0
    var isArchived: Bool = false
    var animal: Animal?
    @Relationship(deleteRule: .deny, inverse: \Press.button) var presses: [Press]?
}
@Model final class Press {
    id, createdAt
    var timestamp: Date = Date()
    var kindRaw: String = PressKind.spontaneous.rawValue   // kind: PressKind
    var note: String?
    var editedAt: Date?
    var button: AACButton?
    var animal: Animal?
}
@Model final class FeedDay {
    id, createdAt
    var date: Date = Calendar.current.startOfDay(for: Date())   // local start of day, unique per animal by convention
    var outdoorHours: Double?
    var outdoorAreaAcres: Double?
    var note: String?
    var animal: Animal?
    @Relationship(deleteRule: .cascade, inverse: \Feeding.day) var feedings: [Feeding]?
}
@Model final class Feeding {
    id, createdAt
    var time: Date = Date()
    var note: String?
    var day: FeedDay?
    @Relationship(deleteRule: .cascade, inverse: \FeedItem.feeding) var items: [FeedItem]?
}
@Model final class FeedItem {
    id, createdAt
    var categoryRaw: String = FeedCategory.forage.rawValue   // category: FeedCategory
    var type: String = ""
    var amount: Double = 0
    var unit: String = ""
    var sortOrder: Int = 0
    var feeding: Feeding?
}
@Model final class PoopTag {
    id, createdAt
    var name: String = ""
    var colorHex: String = ColorPalette.defaultHex
    var isBuiltIn: Bool = false
    var isHidden: Bool = false
    var sortOrder: Int = 0
    @Relationship(inverse: \PoopObservation.tags) var observations: [PoopObservation]?
}
@Model final class PoopObservation {
    id, createdAt
    var timestamp: Date = Date()
    var tags: [PoopTag]?
    var note: String?
    var editedAt: Date?
    var animal: Animal?
}
@Model final class HealthCheckIn {
    id, createdAt
    var timestamp: Date = Date()
    var photoFilename: String?
    var thumbnailFilename: String?
    var videoFilename: String?
    var note: String?
    var editedAt: Date?
    var animal: Animal?
}
@Model final class OralCheckIn {
    id, createdAt
    var startedAt: Date = Date()
    var endedAt: Date?
    var statusRaw: String = CheckInStatus.inProgress.rawValue   // status: CheckInStatus
    var model: String = ""
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var createdRecordIdsJSON: String = "[]"   // [UUID] as JSON
    var errorMessage: String?
    var animal: Animal?
    @Relationship(deleteRule: .cascade, inverse: \CheckInTurn.checkIn) var turns: [CheckInTurn]?
}
@Model final class CheckInTurn {
    id, createdAt
    var index: Int = 0
    var roleRaw: String = TurnRole.user.rawValue   // role: TurnRole
    var text: String = ""
    var timestamp: Date = Date()
    var draftJSON: String?
    var checkIn: OralCheckIn?
}
@Model final class VoiceRecording {
    id, createdAt
    var recordedAt: Date = Date()
    var durationS: Double = 0
    var audioFilename: String = ""            // "<uuid>-audio.m4a"
    var statusRaw: String = VoiceStatus.recorded.rawValue   // status: VoiceStatus
    var errorMessage: String?
    var note: String = ""
    var activityTag: String?
    var meaningTag: String?
    var userConfidence: Int?                  // 1 guess, 2 fairly sure, 3 certain
    var editedAt: Date?
    var animal: Animal?
    @Relationship(deleteRule: .cascade, inverse: \Vocalization.recording) var vocalizations: [Vocalization]?
}
@Model final class Vocalization {
    id, createdAt
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
    var recording: VoiceRecording?
}
@Model final class VoiceTag {
    id, createdAt
    var kindRaw: String = VoiceTagKind.activity.rawValue   // kind: VoiceTagKind
    var name: String = ""
    var isBuiltIn: Bool = false
    var sortOrder: Int = 0
}
```

## Snapshots (App/Logic/Snapshots.swift)

`AnimalSnapshot` exists. Each plan adds its own, with exactly these names and fields:

- `PressSnapshot(id: UUID, timestamp: Date, buttonID: UUID, buttonLabel: String, buttonColorHex: String, kind: PressKind, note: String?)`
- `FeedingSnapshot(id: UUID, time: Date, note: String?, items: [FeedItemSnapshot])`, `FeedItemSnapshot(id: UUID, category: FeedCategory, type: String, amount: Double, unit: String, sortOrder: Int, createdAt: Date)`
- `PoopSnapshot(id: UUID, timestamp: Date, tagNames: [String], note: String?)`
- `HealthSnapshot(id: UUID, timestamp: Date, photoFilename: String?, videoFilename: String?, note: String?)`

## Export contract (Plan G reads every model above)

CSV headers and JSON version 4 keys are fixed in the spec's Data handling section. Dates are ISO 8601 with fractional seconds omitted, local time zone offset included. FeedDay `date` exports as `yyyy-MM-dd`.
