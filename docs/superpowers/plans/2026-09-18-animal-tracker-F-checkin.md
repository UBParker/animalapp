# AnimalTracker Plan F: Oral AI Check-In Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the oral check-in subsystem: the keeper talks once a day, Claude extracts a structured draft and asks one short follow-up question at a time, and the reviewed draft is committed as a FeedDay, Feedings with FeedItems, a PoopObservation and a HealthCheckIn note in one transaction.

**Architecture:** Three layers with no leakage between them. The wire layer (`ClaudeRequestBuilder`, `ClaudeResponseParser`, `ClaudeClient`) knows HTTP and JSON but nothing about SwiftData. The logic layer (`CheckInDraft`, `CheckInSchema`, `SystemPromptBuilder`, `DraftMapper`, `CheckInSession`) is pure value code over snapshots, depending only on the `ClaudeClient` and `Transcriber` protocols, so every state transition and mapping rule is unit-tested without a container or a socket. The persistence layer (`OralCheckIn`, `CheckInTurn`, `CheckInCommitter`) is the only place that touches `ModelContext`, and it writes everything in one `context.save()`.

**Tech Stack:** Swift 5 language mode, SwiftUI, SwiftData, Speech (`SFSpeechRecognizer`), AVFoundation (`AVAudioEngine`, `AVSpeechSynthesizer`), Foundation `URLSession`, Security (via Plan A's `KeychainStore`), XCTest.

**Spec:** `docs/superpowers/specs/2026-09-16-animal-tracker-design.md` (sections: Constraints, Data model / Oral check-in domain, Settings, Oral check-in sheet, Claude request, Logic, Error handling, Testing) and `docs/superpowers/specs/2026-09-18-model-contract.md` (binding model names and registration points). Depends on Plan A (foundation) and on Plans C (buttons), D (feed), E (poop + health) being implemented first.

## Global Constraints

- iOS deployment target `17.0`; Swift 5 language mode (`SWIFT_VERSION = 5.0`); never Swift 6 strict concurrency.
- App target `AnimalTracker`, test target `AnimalTrackerTests`, test files use `@testable import AnimalTracker`. Tests live in `AppTests/` and run with `scripts/test-app.sh`.
- No third-party packages, no iCloud, no analytics. The only network call in the whole app is the one this plan adds.
- SwiftData store is local: `ModelConfiguration(cloudKitDatabase: .none)`; tests use `TestSupport.container()` (in-memory) and only where the test must touch the store.
- Every model has `var id: UUID = UUID()` and `var createdAt: Date = Date()`. Enum-backed fields are stored as `<name>Raw: String` with a computed `<name>` accessor. Every stored property has a default or is optional. Relationships are optional.
- The Anthropic API key is read from `KeychainStore(service: "AnimalTracker").get(KeychainStore.apiKeyAccount)` at request time, put only into the `x-api-key` header, and never written to a log, the store, an export, or an error message.
- Settings keys already created by Plan A: `@AppStorage("checkInQuestionCap")` default `8`, `@AppStorage("speakQuestions")` default `true`. This plan adds `@AppStorage("hasAcknowledgedCheckInPrivacy")` default `false`.
- Info.plist already carries `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription` from Plan A Task 1. Do not edit `project.yml`.
- Claude request, verbatim from the spec: `POST https://api.anthropic.com/v1/messages`, `model: "claude-opus-5"`, `max_tokens: 4096`, `thinking: {type: "adaptive"}`, `fallbacks: "default"`, `output_config.format` = the strict `CheckInDraft` JSON schema, `system` = the built prompt, `messages` = the conversation so far. 60 s timeout, one automatic retry on connection failure or HTTP 429/5xx, no streaming.
- Commit after every task with the message shown; do not push. Every commit message ends with the trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.

## Assumptions

Decisions the spec left open, and how this plan resolves them.

- **claude-api reference used.** Header names, the model id, the structured-output body shape, the fallback beta header, the stop-reason set and the usage field names were taken from the bundled `claude-api` skill at `/private/tmp/claude-501/bundled-skills/2.1.271/d01df5c7c98d2ae5c0b01647c4029ad7/claude-api/`, specifically `curl/examples.md` (endpoint, the four required headers, `x-api-key`, `anthropic-version: 2023-06-01`, adaptive thinking body shape, `usage.input_tokens` / `usage.output_tokens`, `stop_reason`), `shared/tool-use-concepts.md` § Structured Outputs (`output_config.format` with `{"type": "json_schema", "schema": ...}`, the supported-keyword list, `additionalProperties: false` required on every object, refusal and max_tokens caveats) and `shared/model-migration.md` (the `fallbacks: "default"` scalar form and its beta header `server-side-fallback-2026-07-01`, and `stop_details` being populated only when `stop_reason == "refusal"`). The project is Swift, which has no official Anthropic SDK, so the reference's raw-HTTP guidance applies and the request is built by hand with `URLSession`.
- **"Strict" schema.** `strict: true` is a field on *tool* definitions, not on `output_config.format`. A `json_schema` response format is already constrained decoding, so "strict" is expressed the way the reference requires: `additionalProperties: false` on every object and every property listed in `required`. Optional values are nullable rather than absent, written as `anyOf: [{...}, {"type": "null"}]` because `anyOf` and the `null` type are both on the reference's supported list.
- **`max_tokens` stays at 4096.** The reference recommends ~16000 for non-streaming requests, but the spec fixes 4096 and pairs it with an explicit max_tokens retry asking for brevity. The spec wins; the retry path covers the truncation case.
- **Retry budget.** "One automatic retry" is per request, in `LiveClaudeClient`. The separate max_tokens brevity retry lives in `CheckInSession` and also fires at most once per session.
- **Exhausted brevity retry.** The spec says max_tokens retries once but does not say what happens if the retry is also truncated. Treated like unparseable JSON: Review opens with an empty draft and the check-in is marked failed with that reason.
- **`failed` versus `reviewing`.** The spec requires both a `failed` terminal state and "Review is always reachable". Resolved by separating them: a refusal, unparseable JSON, a missing key or a network error sets `failureReason` and moves to `reviewing` (transcript intact, empty draft), and the persisted `OralCheckIn.status` becomes `failed` with that reason at that moment. The `failed` *state* is entered only when the final save transaction itself throws.
- **Snapshot types.** The model contract does not define a FeedDay snapshot or a PoopTag snapshot, and Plans D and E own `App/Logic/Snapshots.swift`. To avoid colliding with their additions, this plan defines `ExistingFeedDaySnapshot` and `CheckInTagOption` inside `App/CheckIn/DraftMapper.swift` instead of adding to `Snapshots.swift`.
- **Review editors.** The spec says each mapped record is shown "with its tab's editor". Naming Plan D and Plan E view types would couple this plan to view names the contract does not fix, so Review uses inline editors local to Plan F (text fields, steppers, date pickers bound to `MappedRecords`). The records are still committed through the same models.
- **Poop with no recognized tag.** A `PoopObservation` needs at least one tag (the Poop tab disables Save with zero tags). If every drafted tag is unrecognized, no observation is created; the unrecognized names and the dropped note are both surfaced as warnings so nothing disappears silently.
- **Concurrency.** `ClaudeClient`, `Transcriber` and `CheckInSession` are all `@MainActor`. The async `send` suspends, so URLSession still does its work off the main thread, and this keeps Swift 5 free of actor-isolation warnings without adopting strict concurrency.
- **Model initializers.** The contract gives every stored property a default, so the `@Model` macro's generated initializer is used (`FeedDay()`, `Feeding()`, and so on) and properties are assigned afterwards.
- **No Settings change.** Plan A's `SettingsView` already ships the API key field, the question-cap stepper and the speak-questions toggle, so there is no `SettingsPlaceholderRow` for this plan to replace.

## File Structure

```
App/Models/OralCheckIn.swift              OralCheckIn + CheckInTurn models
App/Persistence/PersistenceController.swift   append two model types (modify)
App/Persistence/AnimalDeletionPolicy.swift    append the "oral check-ins" count (modify)
App/CheckIn/CheckInDraft.swift            Codable draft + CheckInField key list
App/CheckIn/CheckInSchema.swift           the strict JSON schema dictionary
App/CheckIn/ClaudeResponse.swift          ClaudeResponse + ClaudeResponseParser
App/CheckIn/ClaudeRequestBuilder.swift    ClaudeMessage + URLRequest builder
App/CheckIn/ClaudeClient.swift            protocol, LiveClaudeClient, retry policy, ScriptedClaudeClient
App/CheckIn/SystemPromptBuilder.swift     system prompt from animal + vocabulary
App/CheckIn/DraftMapper.swift             draft -> MappedRecords with warnings
App/CheckIn/Transcriber.swift             protocol + ScriptedTranscriber
App/CheckIn/SpeechTranscriber.swift       SFSpeechRecognizer implementation
App/CheckIn/QuestionSpeaker.swift         AVSpeechSynthesizer wrapper
App/CheckIn/CheckInSession.swift          @Observable state machine
App/CheckIn/CheckInCommitter.swift        the only SwiftData writer
App/Views/CheckIn/CheckInSheetView.swift  privacy, missing key, talk, question
App/Views/CheckIn/CheckInReviewView.swift review and save
App/AnimalSwitcher.swift                  replace the OralCheckInEntry placeholder (modify)

AppTests/OralCheckInModelTests.swift
AppTests/CheckInDraftTests.swift
AppTests/ClaudeResponseParserTests.swift
AppTests/ClaudeRequestBuilderTests.swift
AppTests/ClaudeClientTests.swift
AppTests/SystemPromptBuilderTests.swift
AppTests/DraftMapperTests.swift
AppTests/TranscriberTests.swift
AppTests/CheckInSessionTests.swift
AppTests/CheckInCommitterTests.swift
```

---

### Task 1: OralCheckIn and CheckInTurn models, registered

Adds 4 tests.

**Files:**
- Create: `App/Models/OralCheckIn.swift`
- Modify: `App/Persistence/PersistenceController.swift`, `App/Persistence/AnimalDeletionPolicy.swift`
- Test: `AppTests/OralCheckInModelTests.swift`

**Interfaces:**
- Consumes: `Animal`, `CheckInStatus` (inProgress, reviewed, saved, discarded, failed), `TurnRole` (user, assistant), `PersistenceController.modelTypes`, `AnimalDeletionPolicy.recordCounts(for:context:)`, `TestSupport.container()` from Plan A.
- Produces: `@Model final class OralCheckIn` with `id, createdAt, startedAt, endedAt, statusRaw, status, model, inputTokens, outputTokens, createdRecordIdsJSON, createdRecordIds, errorMessage, animal, turns`; `@Model final class CheckInTurn` with `id, createdAt, index, roleRaw, role, text, timestamp, draftJSON, checkIn`; an `"oral check-ins"` entry in `AnimalDeletionPolicy.recordCounts`.

- [ ] **Step 1: Write the failing test**

`AppTests/OralCheckInModelTests.swift`:
```swift
import SwiftData
import XCTest
@testable import AnimalTracker

@MainActor
final class OralCheckInModelTests: XCTestCase {
    func testDefaultsAndRoundTrip() throws {
        let context = try TestSupport.container().mainContext
        let animal = Animal(name: "Juniper", species: "horse")
        context.insert(animal)
        let checkIn = OralCheckIn()
        checkIn.animal = animal
        checkIn.model = "claude-opus-5"
        context.insert(checkIn)
        try context.save()

        let fetched = try XCTUnwrap(context.fetch(FetchDescriptor<OralCheckIn>()).first)
        XCTAssertEqual(fetched.status, .inProgress)
        XCTAssertEqual(fetched.inputTokens, 0)
        XCTAssertEqual(fetched.outputTokens, 0)
        XCTAssertEqual(fetched.createdRecordIdsJSON, "[]")
        XCTAssertEqual(fetched.createdRecordIds, [])
        XCTAssertNil(fetched.endedAt)
        XCTAssertNil(fetched.errorMessage)
        XCTAssertEqual(fetched.animal?.name, "Juniper")
    }

    func testStatusAndRoleAccessorsWriteRawValues() throws {
        let context = try TestSupport.container().mainContext
        let checkIn = OralCheckIn()
        context.insert(checkIn)
        checkIn.status = .failed
        XCTAssertEqual(checkIn.statusRaw, "failed")

        let turn = CheckInTurn()
        turn.checkIn = checkIn
        turn.role = .assistant
        turn.index = 3
        turn.text = "How much hay?"
        context.insert(turn)
        try context.save()
        XCTAssertEqual(turn.roleRaw, "assistant")
        XCTAssertEqual(checkIn.turns?.count, 1)
    }

    func testTurnsCascadeOnDelete() throws {
        let context = try TestSupport.container().mainContext
        let checkIn = OralCheckIn()
        context.insert(checkIn)
        for index in 0..<3 {
            let turn = CheckInTurn()
            turn.index = index
            turn.text = "turn \(index)"
            turn.checkIn = checkIn
            context.insert(turn)
        }
        try context.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<CheckInTurn>()).count, 3)
        context.delete(checkIn)
        try context.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<CheckInTurn>()).count, 0)
    }

    func testDeletionPolicyCountsOralCheckIns() throws {
        let context = try TestSupport.container().mainContext
        let animal = Animal(name: "Juniper", species: "horse")
        context.insert(animal)
        XCTAssertEqual(try AnimalDeletionPolicy.recordCounts(for: animal, context: context)["oral check-ins"], 0)

        let checkIn = OralCheckIn()
        checkIn.animal = animal
        context.insert(checkIn)
        try context.save()
        XCTAssertEqual(try AnimalDeletionPolicy.recordCounts(for: animal, context: context)["oral check-ins"], 1)
        XCTAssertFalse(try AnimalDeletionPolicy.canDelete(animal, context: context))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test-app.sh`
Expected: build errors, `OralCheckIn` and `CheckInTurn` not found.

- [ ] **Step 3: Implement**

`App/Models/OralCheckIn.swift`:
```swift
import Foundation
import SwiftData

/// One spoken check-in session. Turns are kept even when the session is discarded, so the
/// transcript is never lost.
@Model
final class OralCheckIn {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var startedAt: Date = Date()
    var endedAt: Date?
    var statusRaw: String = CheckInStatus.inProgress.rawValue
    /// The Claude model id the request named, e.g. "claude-opus-5".
    var model: String = ""
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    /// The ids of the records this check-in created, as a JSON array of UUID strings.
    var createdRecordIdsJSON: String = "[]"
    var errorMessage: String?
    var animal: Animal?
    @Relationship(deleteRule: .cascade, inverse: \CheckInTurn.checkIn) var turns: [CheckInTurn]?

    var status: CheckInStatus {
        get { CheckInStatus(rawValue: statusRaw) ?? .inProgress }
        set { statusRaw = newValue.rawValue }
    }

    var createdRecordIds: [UUID] {
        guard let data = createdRecordIdsJSON.data(using: .utf8),
              let strings = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return strings.compactMap { UUID(uuidString: $0) }
    }

    var orderedTurns: [CheckInTurn] {
        (turns ?? []).sorted { $0.index < $1.index }
    }
}

/// One message in the check-in conversation. Assistant turns carry the raw JSON draft they produced.
@Model
final class CheckInTurn {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var index: Int = 0
    var roleRaw: String = TurnRole.user.rawValue
    var text: String = ""
    var timestamp: Date = Date()
    var draftJSON: String?
    var checkIn: OralCheckIn?

    var role: TurnRole {
        get { TurnRole(rawValue: roleRaw) ?? .user }
        set { roleRaw = newValue.rawValue }
    }
}
```

- [ ] **Step 4: Register the models**

In `App/Persistence/PersistenceController.swift`, add two lines to the `modelTypes` array, immediately before its closing `]`:
```swift
        OralCheckIn.self,
        CheckInTurn.self,
```

In `App/Persistence/AnimalDeletionPolicy.swift`, inside `recordCounts(for:context:)`, add this immediately before `return counts`:
```swift
        counts["oral check-ins"] = try context.fetch(FetchDescriptor<OralCheckIn>())
            .filter { $0.animal?.id == animal.id }.count
```
If Plan A's placeholder lines `_ = animal` and `_ = context` are still present, delete them now; they are redundant once a real count uses both.

- [ ] **Step 5: Run to verify pass**

Run: `scripts/test-app.sh`
Expected: the four `OralCheckInModelTests` pass, every earlier test still passes.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(checkin): OralCheckIn and CheckInTurn models registered in the schema and deletion policy

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: CheckInDraft and the strict CheckInSchema

Adds 6 tests. No SwiftData, no network.

**Files:**
- Create: `App/CheckIn/CheckInDraft.swift`, `App/CheckIn/CheckInSchema.swift`
- Test: `AppTests/CheckInDraftTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `enum CheckInField: String, CaseIterable` with cases `outdoorHours, outdoorArea, forage, food, supplements, poop, health` and `static func order(tracksOutdoorTime: Bool) -> [CheckInField]` plus `var prompt: String`; `struct CheckInDraft: Codable, Equatable` with nested `FeedDayDraft`, `FeedingDraft`, `ItemDraft`, `PoopDraft`, `HealthDraft`, `static let empty`, `static func decode(_ json: String) -> CheckInDraft?`, `func encodedJSON() -> String?`; `enum CheckInSchema` with `static let dictionary: [String: Any]` and `static let categoryValues: [String]`.

- [ ] **Step 1: Write the failing test**

`AppTests/CheckInDraftTests.swift`:
```swift
import XCTest
@testable import AnimalTracker

final class CheckInDraftTests: XCTestCase {
    private let fullJSON = #"""
    {
      "feedDay": {"outdoorHours": 6.5, "outdoorAreaAcres": 2, "note": "muddy"},
      "feedings": [
        {"time": "07:30", "items": [
          {"category": "forage", "type": "hay", "amount": 2, "unit": "flakes"},
          {"category": "supplement", "type": "MSM", "amount": null, "unit": null}
        ], "note": "ate it all"}
      ],
      "poop": {"tags": ["normal", "large volume"], "note": null},
      "health": {"note": "acting normally"},
      "missing": ["food"],
      "nextQuestion": "Any grain today?",
      "done": false
    }
    """#

    func testDecodesEveryField() throws {
        let draft = try XCTUnwrap(CheckInDraft.decode(fullJSON))
        XCTAssertEqual(draft.feedDay?.outdoorHours, 6.5)
        XCTAssertEqual(draft.feedDay?.outdoorAreaAcres, 2)
        XCTAssertEqual(draft.feedDay?.note, "muddy")
        XCTAssertEqual(draft.feedings.count, 1)
        XCTAssertEqual(draft.feedings[0].time, "07:30")
        XCTAssertEqual(draft.feedings[0].items.count, 2)
        XCTAssertEqual(draft.feedings[0].items[0].category, "forage")
        XCTAssertEqual(draft.feedings[0].items[0].amount, 2)
        XCTAssertNil(draft.feedings[0].items[1].amount)
        XCTAssertNil(draft.feedings[0].items[1].unit)
        XCTAssertEqual(draft.poop?.tags, ["normal", "large volume"])
        XCTAssertNil(draft.poop?.note)
        XCTAssertEqual(draft.health?.note, "acting normally")
        XCTAssertEqual(draft.missing, ["food"])
        XCTAssertEqual(draft.nextQuestion, "Any grain today?")
        XCTAssertFalse(draft.done)
    }

    func testDecodesNullsAndMissingKeysAsEmpty() throws {
        let draft = try XCTUnwrap(CheckInDraft.decode(#"{"feedDay": null, "done": true}"#))
        XCTAssertNil(draft.feedDay)
        XCTAssertEqual(draft.feedings, [])
        XCTAssertNil(draft.poop)
        XCTAssertNil(draft.health)
        XCTAssertEqual(draft.missing, [])
        XCTAssertNil(draft.nextQuestion)
        XCTAssertTrue(draft.done)
        XCTAssertEqual(CheckInDraft.empty.feedings, [])
        XCTAssertFalse(CheckInDraft.empty.done)
    }

    func testDecodeRejectsGarbage() {
        XCTAssertNil(CheckInDraft.decode("not json"))
        XCTAssertNil(CheckInDraft.decode(#"{"done": "yes"}"#))
    }

    func testRoundTripsThroughEncodedJSON() throws {
        let original = try XCTUnwrap(CheckInDraft.decode(fullJSON))
        let text = try XCTUnwrap(original.encodedJSON())
        XCTAssertEqual(CheckInDraft.decode(text), original)
    }

    func testFieldOrderMatchesTheSpec() {
        XCTAssertEqual(CheckInField.order(tracksOutdoorTime: true).map(\.rawValue),
                       ["outdoorHours", "outdoorArea", "forage", "food", "supplements", "poop", "health"])
        XCTAssertEqual(CheckInField.order(tracksOutdoorTime: false).map(\.rawValue),
                       ["forage", "food", "supplements", "poop", "health"])
        XCTAssertEqual(CheckInField.allCases.count, 7)
    }

    func testSchemaMirrorsTheDraftAndIsStrict() throws {
        let schema = CheckInSchema.dictionary
        XCTAssertTrue(JSONSerialization.isValidJSONObject(schema))

        let root = try XCTUnwrap(schema as? [String: Any])
        XCTAssertEqual(root["type"] as? String, "object")
        XCTAssertEqual(root["additionalProperties"] as? Bool, false)
        let properties = try XCTUnwrap(root["properties"] as? [String: Any])
        let required = try XCTUnwrap(root["required"] as? [String])
        XCTAssertEqual(Set(properties.keys),
                       ["feedDay", "feedings", "poop", "health", "missing", "nextQuestion", "done"])
        XCTAssertEqual(Set(required), Set(properties.keys))

        // Every nested object is closed and lists all of its own properties as required.
        func audit(_ node: Any) {
            guard let object = node as? [String: Any] else { return }
            if object["type"] as? String == "object" {
                XCTAssertEqual(object["additionalProperties"] as? Bool, false)
                let props = (object["properties"] as? [String: Any]) ?? [:]
                XCTAssertEqual(Set((object["required"] as? [String]) ?? []), Set(props.keys))
                props.values.forEach(audit)
            }
            (object["items"]).map(audit)
            ((object["anyOf"] as? [Any]) ?? []).forEach(audit)
            ((object["properties"] as? [String: Any]) ?? [:]).values.forEach(audit)
        }
        audit(root)

        let item = try XCTUnwrap(((properties["feedings"] as? [String: Any])?["items"]) as? [String: Any])
        let itemProps = try XCTUnwrap(item["properties"] as? [String: Any])
        XCTAssertEqual(Set(itemProps.keys), ["time", "items", "note"])
        let feedItem = try XCTUnwrap((itemProps["items"] as? [String: Any])?["items"] as? [String: Any])
        let feedItemProps = try XCTUnwrap(feedItem["properties"] as? [String: Any])
        XCTAssertEqual(Set(feedItemProps.keys), ["category", "type", "amount", "unit"])
        XCTAssertEqual((feedItemProps["category"] as? [String: Any])?["enum"] as? [String],
                       ["forage", "food", "supplement", "treat"])
        let missing = try XCTUnwrap(properties["missing"] as? [String: Any])
        XCTAssertEqual((missing["items"] as? [String: Any])?["enum"] as? [String],
                       CheckInField.allCases.map(\.rawValue))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test-app.sh`
Expected: build errors, `CheckInDraft`, `CheckInField` and `CheckInSchema` not found.

- [ ] **Step 3: Implement**

`App/CheckIn/CheckInDraft.swift`:
```swift
import Foundation

/// The fixed field-key list the model may put in `missing`, in the order the spec asks them.
enum CheckInField: String, CaseIterable {
    case outdoorHours
    case outdoorArea
    case forage
    case food
    case supplements
    case poop
    case health

    /// The question order. Outdoor fields are skipped for animals that do not track outdoor time.
    static func order(tracksOutdoorTime: Bool) -> [CheckInField] {
        tracksOutdoorTime ? allCases : allCases.filter { $0 != .outdoorHours && $0 != .outdoorArea }
    }

    /// What the field means, for the system prompt.
    var prompt: String {
        switch self {
        case .outdoorHours: return "how many hours the animal was outdoors"
        case .outdoorArea: return "how many acres the outdoor area is"
        case .forage: return "what forage was fed and how much"
        case .food: return "what food was fed, the type and the amount"
        case .supplements: return "which supplements were given"
        case .poop: return "whether the poop was normal, or which tags apply"
        case .health: return "any wellbeing concern"
        }
    }
}

/// Mirrors the JSON schema sent to the API exactly. Decoding is tolerant of missing keys so a
/// truncated-but-parseable answer still yields whatever the model managed to say.
struct CheckInDraft: Codable, Equatable {
    struct FeedDayDraft: Codable, Equatable {
        var outdoorHours: Double?
        var outdoorAreaAcres: Double?
        var note: String?

        init(outdoorHours: Double? = nil, outdoorAreaAcres: Double? = nil, note: String? = nil) {
            self.outdoorHours = outdoorHours
            self.outdoorAreaAcres = outdoorAreaAcres
            self.note = note
        }
    }

    struct ItemDraft: Codable, Equatable {
        var category: String
        var type: String
        var amount: Double?
        var unit: String?

        init(category: String, type: String, amount: Double? = nil, unit: String? = nil) {
            self.category = category
            self.type = type
            self.amount = amount
            self.unit = unit
        }
    }

    struct FeedingDraft: Codable, Equatable {
        var time: String?
        var items: [ItemDraft]
        var note: String?

        init(time: String? = nil, items: [ItemDraft] = [], note: String? = nil) {
            self.time = time
            self.items = items
            self.note = note
        }

        enum CodingKeys: String, CodingKey { case time, items, note }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            time = try c.decodeIfPresent(String.self, forKey: .time)
            items = try c.decodeIfPresent([ItemDraft].self, forKey: .items) ?? []
            note = try c.decodeIfPresent(String.self, forKey: .note)
        }
    }

    struct PoopDraft: Codable, Equatable {
        var tags: [String]
        var note: String?

        init(tags: [String] = [], note: String? = nil) {
            self.tags = tags
            self.note = note
        }

        enum CodingKeys: String, CodingKey { case tags, note }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
            note = try c.decodeIfPresent(String.self, forKey: .note)
        }
    }

    struct HealthDraft: Codable, Equatable {
        var note: String?

        init(note: String? = nil) { self.note = note }
    }

    var feedDay: FeedDayDraft?
    var feedings: [FeedingDraft]
    var poop: PoopDraft?
    var health: HealthDraft?
    var missing: [String]
    var nextQuestion: String?
    var done: Bool

    init(feedDay: FeedDayDraft? = nil, feedings: [FeedingDraft] = [], poop: PoopDraft? = nil,
         health: HealthDraft? = nil, missing: [String] = [], nextQuestion: String? = nil, done: Bool = false) {
        self.feedDay = feedDay
        self.feedings = feedings
        self.poop = poop
        self.health = health
        self.missing = missing
        self.nextQuestion = nextQuestion
        self.done = done
    }

    enum CodingKeys: String, CodingKey {
        case feedDay, feedings, poop, health, missing, nextQuestion, done
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        feedDay = try c.decodeIfPresent(FeedDayDraft.self, forKey: .feedDay)
        feedings = try c.decodeIfPresent([FeedingDraft].self, forKey: .feedings) ?? []
        poop = try c.decodeIfPresent(PoopDraft.self, forKey: .poop)
        health = try c.decodeIfPresent(HealthDraft.self, forKey: .health)
        missing = try c.decodeIfPresent([String].self, forKey: .missing) ?? []
        nextQuestion = try c.decodeIfPresent(String.self, forKey: .nextQuestion)
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
    }

    static let empty = CheckInDraft()

    static func decode(_ json: String) -> CheckInDraft? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(CheckInDraft.self, from: data)
    }

    func encodedJSON() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
```

`App/CheckIn/CheckInSchema.swift`:
```swift
import Foundation

/// The JSON schema sent as `output_config.format`. Strict in the sense the API requires:
/// every object closes with `additionalProperties: false` and lists all of its properties in
/// `required`, so optional values are nullable rather than absent.
enum CheckInSchema {
    static let categoryValues = ["forage", "food", "supplement", "treat"]

    static var dictionary: [String: Any] { root }

    private static func nullable(_ type: String) -> [String: Any] {
        ["anyOf": [["type": type], ["type": "null"]]]
    }

    private static func nullableObject(_ object: [String: Any]) -> [String: Any] {
        ["anyOf": [object, ["type": "null"]]]
    }

    private static let feedDay: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": ["outdoorHours", "outdoorAreaAcres", "note"],
        "properties": [
            "outdoorHours": nullable("number"),
            "outdoorAreaAcres": nullable("number"),
            "note": nullable("string"),
        ],
    ]

    private static let feedItem: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": ["category", "type", "amount", "unit"],
        "properties": [
            "category": ["type": "string", "enum": categoryValues],
            "type": ["type": "string"],
            "amount": nullable("number"),
            "unit": nullable("string"),
        ],
    ]

    private static let feeding: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": ["time", "items", "note"],
        "properties": [
            "time": nullable("string"),
            "items": ["type": "array", "items": feedItem],
            "note": nullable("string"),
        ],
    ]

    private static let poop: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": ["tags", "note"],
        "properties": [
            "tags": ["type": "array", "items": ["type": "string"]],
            "note": nullable("string"),
        ],
    ]

    private static let health: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": ["note"],
        "properties": ["note": nullable("string")],
    ]

    private static let root: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": ["feedDay", "feedings", "poop", "health", "missing", "nextQuestion", "done"],
        "properties": [
            "feedDay": nullableObject(feedDay),
            "feedings": ["type": "array", "items": feeding],
            "poop": nullableObject(poop),
            "health": nullableObject(health),
            "missing": ["type": "array",
                        "items": ["type": "string", "enum": CheckInField.allCases.map(\.rawValue)]],
            "nextQuestion": nullable("string"),
            "done": ["type": "boolean"],
        ],
    ]
}
```

- [ ] **Step 4: Run to verify pass**

Run: `scripts/test-app.sh`
Expected: the six `CheckInDraftTests` pass.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(checkin): CheckInDraft codable model and the strict CheckInSchema

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: ClaudeResponseParser against recorded fixtures

Adds 7 tests. No SwiftData, no network.

**Files:**
- Create: `App/CheckIn/ClaudeResponse.swift`
- Test: `AppTests/ClaudeResponseParserTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `struct ClaudeResponse: Equatable` with `stopReason: ClaudeResponse.StopReason`, `jsonText: String?`, `inputTokens: Int`, `outputTokens: Int`, `model: String`, `refusalCategory: String?`, `refusalExplanation: String?` and a memberwise `init`; `enum ClaudeResponse.StopReason: Equatable` with `.endTurn`, `.maxTokens`, `.refusal`, `.other(String)` and `init(raw: String)`; `enum ClaudeParseError: Error, Equatable` with `.notJSON`, `.apiError(type:message:)`, `.missingStopReason`; `enum ClaudeResponseParser` with `static func parse(data: Data) throws -> ClaudeResponse` and `static func errorMessage(in data: Data) -> String?`.

- [ ] **Step 1: Write the failing test**

`AppTests/ClaudeResponseParserTests.swift`:
```swift
import XCTest
@testable import AnimalTracker

/// Recorded response bodies, stored as Swift string literals so the fixtures travel with the test.
enum ClaudeFixtures {
    /// A normal structured-output answer. Thinking blocks come back with empty text by default,
    /// so the parser has to skip them and read only the text block.
    static let endTurn = #"""
    {
      "id": "msg_01AbCdEf",
      "type": "message",
      "role": "assistant",
      "model": "claude-opus-5",
      "content": [
        {"type": "thinking", "thinking": "", "signature": "abc"},
        {"type": "text", "text": "{\"feedDay\":{\"outdoorHours\":6,\"outdoorAreaAcres\":null,\"note\":null},\"feedings\":[],\"poop\":null,\"health\":null,\"missing\":[\"forage\"],\"nextQuestion\":\"What forage did she get?\",\"done\":false}"}
      ],
      "stop_reason": "end_turn",
      "stop_sequence": null,
      "stop_details": null,
      "usage": {"input_tokens": 1843, "output_tokens": 212, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}
    }
    """#

    static let refusal = #"""
    {
      "id": "msg_01RefuSal",
      "type": "message",
      "role": "assistant",
      "model": "claude-opus-5",
      "content": [],
      "stop_reason": "refusal",
      "stop_sequence": null,
      "stop_details": {"type": "refusal", "category": "reasoning_extraction", "explanation": "Declined by a safety classifier."},
      "usage": {"input_tokens": 1200, "output_tokens": 0}
    }
    """#

    static let maxTokens = #"""
    {
      "id": "msg_01TrUnc",
      "type": "message",
      "role": "assistant",
      "model": "claude-opus-5",
      "content": [
        {"type": "text", "text": "{\"feedDay\":{\"outdoorHours\":6,"}
      ],
      "stop_reason": "max_tokens",
      "stop_sequence": null,
      "stop_details": null,
      "usage": {"input_tokens": 1900, "output_tokens": 4096}
    }
    """#

    static let apiError = #"""
    {"type": "error", "error": {"type": "rate_limit_error", "message": "Number of requests has exceeded your rate limit."}}
    """#

    static let malformed = "{\"content\": [{\"type\": \"text\", \"text\": \"oops\"}], \"stop_reason\""
}

final class ClaudeResponseParserTests: XCTestCase {
    private func parse(_ text: String) throws -> ClaudeResponse {
        try ClaudeResponseParser.parse(data: Data(text.utf8))
    }

    func testEndTurnCarriesJSONAndUsage() throws {
        let response = try parse(ClaudeFixtures.endTurn)
        XCTAssertEqual(response.stopReason, .endTurn)
        XCTAssertEqual(response.model, "claude-opus-5")
        XCTAssertEqual(response.inputTokens, 1843)
        XCTAssertEqual(response.outputTokens, 212)
        let json = try XCTUnwrap(response.jsonText)
        XCTAssertTrue(json.hasPrefix("{"))
        let draft = try XCTUnwrap(CheckInDraft.decode(json))
        XCTAssertEqual(draft.feedDay?.outdoorHours, 6)
        XCTAssertEqual(draft.nextQuestion, "What forage did she get?")
        XCTAssertNil(response.refusalCategory)
    }

    func testRefusalCarriesTheCategoryAndNoJSON() throws {
        let response = try parse(ClaudeFixtures.refusal)
        XCTAssertEqual(response.stopReason, .refusal)
        XCTAssertNil(response.jsonText)
        XCTAssertEqual(response.refusalCategory, "reasoning_extraction")
        XCTAssertEqual(response.refusalExplanation, "Declined by a safety classifier.")
        XCTAssertEqual(response.inputTokens, 1200)
        XCTAssertEqual(response.outputTokens, 0)
    }

    func testMaxTokensKeepsTheTruncatedTextButItDoesNotDecode() throws {
        let response = try parse(ClaudeFixtures.maxTokens)
        XCTAssertEqual(response.stopReason, .maxTokens)
        XCTAssertEqual(response.outputTokens, 4096)
        let json = try XCTUnwrap(response.jsonText)
        XCTAssertNil(CheckInDraft.decode(json))
    }

    func testMalformedJSONThrows() {
        XCTAssertThrowsError(try parse(ClaudeFixtures.malformed)) { error in
            XCTAssertEqual(error as? ClaudeParseError, .notJSON)
        }
    }

    func testAPIErrorBodyThrowsWithTheServerMessage() {
        XCTAssertThrowsError(try parse(ClaudeFixtures.apiError)) { error in
            XCTAssertEqual(error as? ClaudeParseError,
                           .apiError(type: "rate_limit_error",
                                     message: "Number of requests has exceeded your rate limit."))
        }
        XCTAssertEqual(ClaudeResponseParser.errorMessage(in: Data(ClaudeFixtures.apiError.utf8)),
                       "Number of requests has exceeded your rate limit.")
        XCTAssertNil(ClaudeResponseParser.errorMessage(in: Data(ClaudeFixtures.endTurn.utf8)))
    }

    func testMissingStopReasonThrows() {
        XCTAssertThrowsError(try parse(#"{"content": [], "usage": {}}"#)) { error in
            XCTAssertEqual(error as? ClaudeParseError, .missingStopReason)
        }
    }

    func testUnknownStopReasonIsPreserved() throws {
        let response = try parse(#"{"stop_reason": "pause_turn", "content": [], "usage": {}}"#)
        XCTAssertEqual(response.stopReason, .other("pause_turn"))
        XCTAssertEqual(response.inputTokens, 0)
        XCTAssertNil(response.jsonText)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test-app.sh`
Expected: build errors, `ClaudeResponse`, `ClaudeParseError` and `ClaudeResponseParser` not found.

- [ ] **Step 3: Implement**

`App/CheckIn/ClaudeResponse.swift`:
```swift
import Foundation

/// What the app needs out of a Messages API response body.
struct ClaudeResponse: Equatable {
    enum StopReason: Equatable {
        case endTurn
        case maxTokens
        case refusal
        case other(String)

        init(raw: String) {
            switch raw {
            case "end_turn": self = .endTurn
            case "max_tokens": self = .maxTokens
            case "refusal": self = .refusal
            default: self = .other(raw)
            }
        }
    }

    let stopReason: StopReason
    /// The concatenated text blocks, trimmed. Nil when the response carried no text.
    let jsonText: String?
    let inputTokens: Int
    let outputTokens: Int
    let model: String
    let refusalCategory: String?
    let refusalExplanation: String?

    init(stopReason: StopReason, jsonText: String?, inputTokens: Int, outputTokens: Int,
         model: String = "claude-opus-5", refusalCategory: String? = nil, refusalExplanation: String? = nil) {
        self.stopReason = stopReason
        self.jsonText = jsonText
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.model = model
        self.refusalCategory = refusalCategory
        self.refusalExplanation = refusalExplanation
    }
}

enum ClaudeParseError: Error, Equatable {
    case notJSON
    case apiError(type: String, message: String)
    case missingStopReason
}

enum ClaudeResponseParser {
    /// `stop_details` is populated only when `stop_reason` is "refusal"; every other stop reason
    /// leaves it null, so it is always read defensively.
    static func parse(data: Data) throws -> ClaudeResponse {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ClaudeParseError.notJSON
        }
        if (root["type"] as? String) == "error" {
            let error = root["error"] as? [String: Any]
            throw ClaudeParseError.apiError(type: error?["type"] as? String ?? "api_error",
                                            message: error?["message"] as? String ?? "The API returned an error.")
        }
        guard let raw = root["stop_reason"] as? String else { throw ClaudeParseError.missingStopReason }

        let blocks = root["content"] as? [[String: Any]] ?? []
        let text = blocks
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let usage = root["usage"] as? [String: Any] ?? [:]
        let details = root["stop_details"] as? [String: Any]

        return ClaudeResponse(
            stopReason: StopReasonFactory.make(raw),
            jsonText: text.isEmpty ? nil : text,
            inputTokens: usage["input_tokens"] as? Int ?? 0,
            outputTokens: usage["output_tokens"] as? Int ?? 0,
            model: root["model"] as? String ?? "",
            refusalCategory: details?["category"] as? String,
            refusalExplanation: details?["explanation"] as? String)
    }

    /// The server's own message from an error body, for a user-facing alert.
    static func errorMessage(in data: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let error = root["error"] as? [String: Any] else { return nil }
        return error["message"] as? String
    }

    private enum StopReasonFactory {
        static func make(_ raw: String) -> ClaudeResponse.StopReason { .init(raw: raw) }
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `scripts/test-app.sh`
Expected: the seven `ClaudeResponseParserTests` pass.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(checkin): ClaudeResponse parser tested against recorded end_turn, refusal, max_tokens and malformed fixtures

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: ClaudeRequestBuilder

Adds 6 tests. No SwiftData, no network.

**Files:**
- Create: `App/CheckIn/ClaudeRequestBuilder.swift`
- Test: `AppTests/ClaudeRequestBuilderTests.swift`

**Interfaces:**
- Consumes: `CheckInSchema.dictionary` (Task 2).
- Produces: `struct ClaudeMessage: Equatable` with `role: String` ("user" or "assistant"), `text: String`, `init(role:text:)`, `static func user(_:)`, `static func assistant(_:)`; `enum ClaudeRequestBuilder` with `static let endpoint: URL`, `static let model = "claude-opus-5"`, `static let maxTokens = 4096`, `static let anthropicVersion = "2023-06-01"`, `static let fallbackBeta = "server-side-fallback-2026-07-01"`, `static let timeout: TimeInterval = 60`, `static func build(system: String, messages: [ClaudeMessage], schema: [String: Any], apiKey: String) throws -> URLRequest`, and `enum ClaudeRequestBuilder.BuildError: Error { case emptyMessages, encodingFailed }`.

- [ ] **Step 1: Write the failing test**

`AppTests/ClaudeRequestBuilderTests.swift`:
```swift
import XCTest
@testable import AnimalTracker

final class ClaudeRequestBuilderTests: XCTestCase {
    private let key = "sk-ant-test-0123456789"

    private func build(_ messages: [ClaudeMessage] = [.user("6 hours out, two flakes of hay.")]) throws -> URLRequest {
        try ClaudeRequestBuilder.build(system: "You fill in an animal care log.",
                                       messages: messages,
                                       schema: CheckInSchema.dictionary,
                                       apiKey: key)
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testEndpointMethodAndTimeout() throws {
        let request = try build()
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.timeoutInterval, 60, accuracy: 0.001)
    }

    func testHeaders() throws {
        let headers = try XCTUnwrap(build().allHTTPHeaderFields)
        XCTAssertEqual(headers["Content-Type"], "application/json")
        XCTAssertEqual(headers["x-api-key"], key)
        XCTAssertEqual(headers["anthropic-version"], "2023-06-01")
        XCTAssertEqual(headers["anthropic-beta"], "server-side-fallback-2026-07-01")
        XCTAssertNil(headers["Authorization"])
    }

    func testBodyTopLevelFields() throws {
        let json = try body(build())
        XCTAssertEqual(json["model"] as? String, "claude-opus-5")
        XCTAssertEqual(json["max_tokens"] as? Int, 4096)
        XCTAssertEqual(json["fallbacks"] as? String, "default")
        XCTAssertEqual((json["thinking"] as? [String: Any])?["type"] as? String, "adaptive")
        XCTAssertEqual(json["system"] as? String, "You fill in an animal care log.")
        XCTAssertNil(json["stream"])
        XCTAssertNil(json["tools"])
    }

    func testBodyCarriesTheStrictSchemaAsTheOutputFormat() throws {
        let json = try body(build())
        let format = try XCTUnwrap((json["output_config"] as? [String: Any])?["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        let schema = try XCTUnwrap(format["schema"] as? [String: Any])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        XCTAssertEqual(Set((schema["required"] as? [String]) ?? []),
                       ["feedDay", "feedings", "poop", "health", "missing", "nextQuestion", "done"])
    }

    func testMessagesAreMappedInOrder() throws {
        let request = try build([.user("six hours out"), .assistant("{\"done\":false}"), .user("two flakes")])
        let messages = try XCTUnwrap(body(request)["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["user", "assistant", "user"])
        XCTAssertEqual(messages[0]["content"] as? String, "six hours out")
        XCTAssertEqual(messages[2]["content"] as? String, "two flakes")
    }

    func testKeyIsOnlyInTheHeaderAndEmptyMessagesThrow() throws {
        let request = try build()
        let bodyText = String(data: try XCTUnwrap(request.httpBody), encoding: .utf8) ?? ""
        XCTAssertFalse(bodyText.contains(key))
        XCTAssertFalse(request.url!.absoluteString.contains(key))
        XCTAssertThrowsError(try ClaudeRequestBuilder.build(system: "s", messages: [],
                                                            schema: CheckInSchema.dictionary, apiKey: key))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test-app.sh`
Expected: build errors, `ClaudeMessage` and `ClaudeRequestBuilder` not found.

- [ ] **Step 3: Implement**

`App/CheckIn/ClaudeRequestBuilder.swift`:
```swift
import Foundation

/// One conversation turn on the wire. Content is plain text; no images or audio are ever sent.
struct ClaudeMessage: Equatable {
    let role: String
    let text: String

    init(role: String, text: String) {
        self.role = role
        self.text = text
    }

    static func user(_ text: String) -> ClaudeMessage { ClaudeMessage(role: "user", text: text) }
    static func assistant(_ text: String) -> ClaudeMessage { ClaudeMessage(role: "assistant", text: text) }
}

/// Builds the Messages API request. Header names and body shape come from the bundled claude-api
/// reference (curl/examples.md for the headers and adaptive thinking, tool-use-concepts.md for
/// output_config.format, model-migration.md for the fallbacks "default" beta header).
enum ClaudeRequestBuilder {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let model = "claude-opus-5"
    static let maxTokens = 4096
    static let anthropicVersion = "2023-06-01"
    static let fallbackBeta = "server-side-fallback-2026-07-01"
    static let timeout: TimeInterval = 60

    enum BuildError: Error, Equatable {
        case emptyMessages
        case encodingFailed
    }

    static func build(system: String, messages: [ClaudeMessage], schema: [String: Any],
                      apiKey: String) throws -> URLRequest {
        guard !messages.isEmpty else { throw BuildError.emptyMessages }

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "thinking": ["type": "adaptive"],
            "fallbacks": "default",
            "output_config": ["format": ["type": "json_schema", "schema": schema]],
            "system": system,
            "messages": messages.map { ["role": $0.role, "content": $0.text] },
        ]
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else {
            throw BuildError.encodingFailed
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The key lives only here. It is never put in the body, the URL, or any log line.
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue(fallbackBeta, forHTTPHeaderField: "anthropic-beta")
        return request
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `scripts/test-app.sh`
Expected: the six `ClaudeRequestBuilderTests` pass.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(checkin): ClaudeRequestBuilder with adaptive thinking, strict output schema and the fallback beta header

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: ClaudeClient protocol, live URLSession client, retry policy, scripted double

Adds 5 tests. No SwiftData, no network (the live client is exercised only through its pure retry policy and error copy).

**Files:**
- Create: `App/CheckIn/ClaudeClient.swift`
- Test: `AppTests/ClaudeClientTests.swift`

**Interfaces:**
- Consumes: `ClaudeMessage`, `ClaudeRequestBuilder.build(system:messages:schema:apiKey:)` (Task 4), `ClaudeResponse`, `ClaudeResponseParser` (Task 3).
- Produces: `@MainActor protocol ClaudeClient` with `func send(system: String, messages: [ClaudeMessage], schema: [String: Any], apiKey: String) async throws -> ClaudeResponse`; `enum ClaudeClientError: LocalizedError, Equatable` with `.missingAPIKey`, `.unauthorized`, `.rateLimited`, `.server(Int)`, `.http(Int, String)`, `.connection(String)`, `.badResponse`; `enum ClaudeRetryPolicy` with `static func shouldRetry(_ error: ClaudeClientError) -> Bool`; `@MainActor final class LiveClaudeClient: ClaudeClient` with `init(session: URLSession = LiveClaudeClient.makeSession())` and `static func makeSession() -> URLSession`; `@MainActor final class ScriptedClaudeClient: ClaudeClient` with `init(_ responses: [Result<ClaudeResponse, Error>])`, `var sentSystems: [String]`, `var sentMessages: [[ClaudeMessage]]`, `var sentAPIKeys: [String]`, `var callCount: Int`.

- [ ] **Step 1: Write the failing test**

`AppTests/ClaudeClientTests.swift`:
```swift
import XCTest
@testable import AnimalTracker

@MainActor
final class ClaudeClientTests: XCTestCase {
    func testRetryPolicyRetriesConnectionRateLimitAndServerErrorsOnly() {
        XCTAssertTrue(ClaudeRetryPolicy.shouldRetry(.connection("offline")))
        XCTAssertTrue(ClaudeRetryPolicy.shouldRetry(.rateLimited))
        XCTAssertTrue(ClaudeRetryPolicy.shouldRetry(.server(500)))
        XCTAssertTrue(ClaudeRetryPolicy.shouldRetry(.server(503)))
        XCTAssertFalse(ClaudeRetryPolicy.shouldRetry(.unauthorized))
        XCTAssertFalse(ClaudeRetryPolicy.shouldRetry(.badResponse))
        XCTAssertFalse(ClaudeRetryPolicy.shouldRetry(.missingAPIKey))
        XCTAssertFalse(ClaudeRetryPolicy.shouldRetry(.http(400, "bad request")))
    }

    func testEveryErrorHasASpecificMessageAndNoneLeakTheKey() {
        let cases: [ClaudeClientError] = [.missingAPIKey, .unauthorized, .rateLimited, .server(502),
                                          .http(400, "invalid_request_error"), .connection("timed out"), .badResponse]
        var seen = Set<String>()
        for error in cases {
            let text = error.errorDescription ?? ""
            XCTAssertFalse(text.isEmpty, "\(error)")
            XCTAssertTrue(seen.insert(text).inserted, "duplicate message for \(error)")
            XCTAssertFalse(text.lowercased().contains("sk-ant"))
        }
        XCTAssertTrue((ClaudeClientError.unauthorized.errorDescription ?? "").contains("Settings"))
    }

    func testScriptedClientReturnsResponsesInOrderAndRecordsWhatWasSent() async throws {
        let first = ClaudeResponse(stopReason: .endTurn, jsonText: #"{"done":false}"#,
                                   inputTokens: 10, outputTokens: 5)
        let second = ClaudeResponse(stopReason: .endTurn, jsonText: #"{"done":true}"#,
                                    inputTokens: 20, outputTokens: 6)
        let client = ScriptedClaudeClient([.success(first), .success(second)])

        let a = try await client.send(system: "S", messages: [.user("one")],
                                      schema: CheckInSchema.dictionary, apiKey: "k1")
        let b = try await client.send(system: "S", messages: [.user("one"), .assistant("{}"), .user("two")],
                                      schema: CheckInSchema.dictionary, apiKey: "k1")
        XCTAssertEqual(a, first)
        XCTAssertEqual(b, second)
        XCTAssertEqual(client.callCount, 2)
        XCTAssertEqual(client.sentSystems, ["S", "S"])
        XCTAssertEqual(client.sentAPIKeys, ["k1", "k1"])
        XCTAssertEqual(client.sentMessages.last?.count, 3)
        XCTAssertEqual(client.sentMessages.last?.last, .user("two"))
    }

    func testScriptedClientThrowsScriptedFailures() async {
        let client = ScriptedClaudeClient([.failure(ClaudeClientError.rateLimited)])
        do {
            _ = try await client.send(system: "S", messages: [.user("x")],
                                      schema: CheckInSchema.dictionary, apiKey: "k")
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? ClaudeClientError, .rateLimited)
        }
    }

    func testScriptedClientRunsOutOfScript() async {
        let client = ScriptedClaudeClient([])
        do {
            _ = try await client.send(system: "S", messages: [.user("x")],
                                      schema: CheckInSchema.dictionary, apiKey: "k")
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? ClaudeClientError, .badResponse)
        }
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test-app.sh`
Expected: build errors, `ClaudeRetryPolicy`, `ClaudeClientError` and `ScriptedClaudeClient` not found.

- [ ] **Step 3: Implement**

`App/CheckIn/ClaudeClient.swift`:
```swift
import Foundation

@MainActor
protocol ClaudeClient: AnyObject {
    func send(system: String, messages: [ClaudeMessage], schema: [String: Any],
              apiKey: String) async throws -> ClaudeResponse
}

enum ClaudeClientError: LocalizedError, Equatable {
    case missingAPIKey
    case unauthorized
    case rateLimited
    case server(Int)
    case http(Int, String)
    case connection(String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No Anthropic API key is saved. Add one in Settings, then start the check-in again."
        case .unauthorized:
            return "Anthropic rejected the API key. Check or replace it in Settings."
        case .rateLimited:
            return "Anthropic is rate limiting this key. Wait a minute and try again."
        case .server(let code):
            return "Anthropic returned a server error (\(code)). Try again shortly."
        case .http(let code, let message):
            return message.isEmpty ? "The request failed with HTTP \(code)."
                                   : "The request failed with HTTP \(code): \(message)"
        case .connection(let detail):
            return "Could not reach Anthropic: \(detail)"
        case .badResponse:
            return "Anthropic sent a response this app could not read."
        }
    }
}

/// One automatic retry, for the failures that are worth retrying: a dropped connection, a 429,
/// or any 5xx. Everything else is returned to the caller immediately.
enum ClaudeRetryPolicy {
    static func shouldRetry(_ error: ClaudeClientError) -> Bool {
        switch error {
        case .connection, .rateLimited, .server:
            return true
        case .missingAPIKey, .unauthorized, .http, .badResponse:
            return false
        }
    }
}

@MainActor
final class LiveClaudeClient: ClaudeClient {
    private let session: URLSession

    init(session: URLSession = LiveClaudeClient.makeSession()) {
        self.session = session
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = ClaudeRequestBuilder.timeout
        config.timeoutIntervalForResource = ClaudeRequestBuilder.timeout
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }

    func send(system: String, messages: [ClaudeMessage], schema: [String: Any],
              apiKey: String) async throws -> ClaudeResponse {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClaudeClientError.missingAPIKey
        }
        let request = try ClaudeRequestBuilder.build(system: system, messages: messages,
                                                     schema: schema, apiKey: apiKey)
        do {
            return try await attempt(request)
        } catch let error as ClaudeClientError where ClaudeRetryPolicy.shouldRetry(error) {
            return try await attempt(request)
        }
    }

    private func attempt(_ request: URLRequest) async throws -> ClaudeResponse {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ClaudeClientError.connection(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw ClaudeClientError.badResponse }
        switch http.statusCode {
        case 200...299:
            do {
                return try ClaudeResponseParser.parse(data: data)
            } catch {
                throw ClaudeClientError.badResponse
            }
        case 401, 403:
            throw ClaudeClientError.unauthorized
        case 429:
            throw ClaudeClientError.rateLimited
        case 500...599:
            throw ClaudeClientError.server(http.statusCode)
        default:
            throw ClaudeClientError.http(http.statusCode, ClaudeResponseParser.errorMessage(in: data) ?? "")
        }
    }
}

/// Test double. Hands back scripted results in order and records what it was asked to send.
@MainActor
final class ScriptedClaudeClient: ClaudeClient {
    private var responses: [Result<ClaudeResponse, Error>]
    private(set) var sentSystems: [String] = []
    private(set) var sentMessages: [[ClaudeMessage]] = []
    private(set) var sentAPIKeys: [String] = []
    private(set) var callCount = 0

    init(_ responses: [Result<ClaudeResponse, Error>]) {
        self.responses = responses
    }

    func send(system: String, messages: [ClaudeMessage], schema: [String: Any],
              apiKey: String) async throws -> ClaudeResponse {
        callCount += 1
        sentSystems.append(system)
        sentMessages.append(messages)
        sentAPIKeys.append(apiKey)
        guard !responses.isEmpty else { throw ClaudeClientError.badResponse }
        return try responses.removeFirst().get()
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `scripts/test-app.sh`
Expected: the five `ClaudeClientTests` pass.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(checkin): ClaudeClient protocol, URLSession client with one retry, and a scripted double

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: SystemPromptBuilder

Adds 6 tests. No SwiftData, no network.

**Files:**
- Create: `App/CheckIn/SystemPromptBuilder.swift`
- Test: `AppTests/SystemPromptBuilderTests.swift`

**Interfaces:**
- Consumes: `CheckInField.order(tracksOutdoorTime:)` and `CheckInField.prompt` (Task 2).
- Produces: `struct SystemPromptInput` with `animalName, species, tracksOutdoorTime, now, buttonLabels, poopTagNames, recentFeedTypes, recentFeedUnits, timeZone` and a memberwise `init` defaulting `timeZone` to `.current`; `enum SystemPromptBuilder` with `static let maxFeedTypes = 20`, `static let maxFeedUnits = 10`, `static func build(_ input: SystemPromptInput) -> String`.

- [ ] **Step 1: Write the failing test**

`AppTests/SystemPromptBuilderTests.swift`:
```swift
import XCTest
@testable import AnimalTracker

final class SystemPromptBuilderTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    /// 2026-09-18 07:05:00 UTC
    private let now = Date(timeIntervalSince1970: 1_789_628_700)

    private func input(tracksOutdoorTime: Bool = true,
                       types: [String] = ["hay", "Purina Senior"],
                       units: [String] = ["flakes", "lb"]) -> SystemPromptInput {
        SystemPromptInput(animalName: "Juniper", species: "horse", tracksOutdoorTime: tracksOutdoorTime,
                          now: now, buttonLabels: ["Out", "Treat"],
                          poopTagNames: ["normal", "soft", "blood"],
                          recentFeedTypes: types, recentFeedUnits: units, timeZone: utc)
    }

    func testIncludesTheAnimalAndTheLocalDateAndTime() {
        let prompt = SystemPromptBuilder.build(input())
        XCTAssertTrue(prompt.contains("Juniper"))
        XCTAssertTrue(prompt.contains("horse"))
        XCTAssertTrue(prompt.contains("2026-09-18"))
        XCTAssertTrue(prompt.contains("07:05"))
    }

    func testIncludesButtonLabelsAndPoopTags() {
        let prompt = SystemPromptBuilder.build(input())
        XCTAssertTrue(prompt.contains("Out, Treat"))
        XCTAssertTrue(prompt.contains("normal, soft, blood"))
    }

    func testCapsVocabularyAtTwentyTypesAndTenUnits() {
        let types = (1...35).map { "type\($0)" }
        let units = (1...25).map { "unit\($0)" }
        let prompt = SystemPromptBuilder.build(input(types: types, units: units))
        XCTAssertTrue(prompt.contains("type20"))
        XCTAssertFalse(prompt.contains("type21"))
        XCTAssertTrue(prompt.contains("unit10"))
        XCTAssertFalse(prompt.contains("unit11"))
    }

    func testFieldOrderIsListedAndSkipsOutdoorWhenNotTracked() {
        let tracked = SystemPromptBuilder.build(input(tracksOutdoorTime: true))
        XCTAssertTrue(tracked.contains("outdoorHours"))
        XCTAssertTrue(tracked.contains("outdoorArea"))
        XCTAssertTrue(tracked.contains("Outdoor time is tracked for this animal."))

        let untracked = SystemPromptBuilder.build(input(tracksOutdoorTime: false))
        XCTAssertFalse(untracked.contains("outdoorHours"))
        XCTAssertFalse(untracked.contains("outdoorArea"))
        XCTAssertTrue(untracked.contains("Outdoor time is not tracked for this animal."))
        XCTAssertTrue(untracked.contains("forage"))
    }

    func testStatesTheOneShortQuestionRuleAndTheNoInventionRule() {
        let prompt = SystemPromptBuilder.build(input())
        XCTAssertTrue(prompt.contains("exactly one"))
        XCTAssertTrue(prompt.contains("20 words"))
        XCTAssertTrue(prompt.contains("Never invent a value"))
        XCTAssertTrue(prompt.contains("\"done\""))
    }

    func testEmptyVocabularyDoesNotProduceDanglingLabels() {
        let prompt = SystemPromptBuilder.build(
            SystemPromptInput(animalName: "Rex", species: "dog", tracksOutdoorTime: false, now: now,
                              buttonLabels: [], poopTagNames: [], recentFeedTypes: [], recentFeedUnits: [],
                              timeZone: utc))
        XCTAssertFalse(prompt.contains("Sound buttons:"))
        XCTAssertFalse(prompt.contains("Recent feed types:"))
        XCTAssertFalse(prompt.contains("Recent units:"))
        XCTAssertTrue(prompt.contains("Poop tags: none are set up yet."))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test-app.sh`
Expected: build errors, `SystemPromptInput` and `SystemPromptBuilder` not found.

- [ ] **Step 3: Implement**

`App/CheckIn/SystemPromptBuilder.swift`:
```swift
import Foundation

struct SystemPromptInput: Equatable {
    let animalName: String
    let species: String
    let tracksOutdoorTime: Bool
    /// Today's date and the local time, as one instant.
    let now: Date
    let buttonLabels: [String]
    let poopTagNames: [String]
    let recentFeedTypes: [String]
    let recentFeedUnits: [String]
    let timeZone: TimeZone

    init(animalName: String, species: String, tracksOutdoorTime: Bool, now: Date,
         buttonLabels: [String], poopTagNames: [String], recentFeedTypes: [String],
         recentFeedUnits: [String], timeZone: TimeZone = .current) {
        self.animalName = animalName
        self.species = species
        self.tracksOutdoorTime = tracksOutdoorTime
        self.now = now
        self.buttonLabels = buttonLabels
        self.poopTagNames = poopTagNames
        self.recentFeedTypes = recentFeedTypes
        self.recentFeedUnits = recentFeedUnits
        self.timeZone = timeZone
    }
}

enum SystemPromptBuilder {
    static let maxFeedTypes = 20
    static let maxFeedUnits = 10

    static func build(_ input: SystemPromptInput) -> String {
        var lines: [String] = []

        lines.append("You help a keeper fill in a daily care log for one animal. The keeper speaks; you turn what they said into the JSON object described by the response schema, and you ask for anything required that is still missing.")
        lines.append("")
        lines.append("Animal: \(input.animalName), species \(input.species).")
        lines.append(input.tracksOutdoorTime
                     ? "Outdoor time is tracked for this animal."
                     : "Outdoor time is not tracked for this animal. Leave outdoorHours and outdoorAreaAcres null and never ask about them.")
        lines.append("Today is \(format(input.now, as: "yyyy-MM-dd", in: input.timeZone)) and the local time is \(format(input.now, as: "HH:mm", in: input.timeZone)). Feeding times are local 24-hour \"HH:mm\".")
        lines.append("")

        if !input.buttonLabels.isEmpty {
            lines.append("Sound buttons this animal has: \(input.buttonLabels.joined(separator: ", ")). They are context only; never log a button press.")
        }
        lines.append(input.poopTagNames.isEmpty
                     ? "Poop tags: none are set up yet. Leave poop null."
                     : "Poop tags you may use, exactly as written: \(input.poopTagNames.joined(separator: ", ")). Use only these names.")
        if !input.recentFeedTypes.isEmpty {
            lines.append("Recent feed types, as spelling hints: \(input.recentFeedTypes.prefix(maxFeedTypes).joined(separator: ", ")).")
        }
        if !input.recentFeedUnits.isEmpty {
            lines.append("Recent units, as spelling hints: \(input.recentFeedUnits.prefix(maxFeedUnits).joined(separator: ", ")).")
        }
        lines.append("")

        lines.append("Required fields, asked one at a time in this order:")
        for (position, field) in CheckInField.order(tracksOutdoorTime: input.tracksOutdoorTime).enumerated() {
            lines.append("\(position + 1). \(field.rawValue) - \(field.prompt)")
        }
        lines.append("")

        lines.append("Rules:")
        lines.append("- Ask exactly one question at a time, in \"nextQuestion\", under 20 words. Never stack two questions into one.")
        lines.append("- Ask only about a field still listed in \"missing\", in the order above.")
        lines.append("- Never invent a value. If the keeper did not say it, leave it null and list its key in \"missing\".")
        lines.append("- If the keeper declines or skips a field, drop it from \"missing\" and never ask about it again.")
        lines.append("- Set \"done\" to true and \"nextQuestion\" to null when nothing required is missing, or when the keeper has declined everything that is left.")
        lines.append("- Carry forward everything the keeper said in earlier turns; each answer is the full record so far, not just the newest part.")
        lines.append("- Reply with the JSON object only. No greeting, no explanation, no markdown fence.")

        return lines.joined(separator: "\n")
    }

    private static func format(_ date: Date, as template: String, in timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = template
        return formatter.string(from: date)
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `scripts/test-app.sh`
Expected: the six `SystemPromptBuilderTests` pass.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(checkin): SystemPromptBuilder with animal context, capped feed vocabulary and the one-question rule

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: DraftMapper and MappedRecords

Adds 10 tests. No SwiftData, no network.

**Files:**
- Create: `App/CheckIn/DraftMapper.swift`
- Test: `AppTests/DraftMapperTests.swift`

**Interfaces:**
- Consumes: `CheckInDraft` (Task 2), `AnimalSnapshot(id:name:species:tracksOutdoorTime:isArchived:sortOrder:)` and `FeedCategory` from Plan A.
- Produces: `struct CheckInTagOption: Equatable, Identifiable` (`id: UUID`, `name: String`); `struct ExistingFeedDaySnapshot: Equatable` (`outdoorHours: Double?`, `outdoorAreaAcres: Double?`, `note: String?`); `struct MappedFeedDay` (`date`, `outdoorHours`, `outdoorAreaAcres`, `note`, all `var`); `struct MappedFeedItem` (`category: FeedCategory`, `type: String`, `amount: Double`, `unit: String`, `sortOrder: Int`); `struct MappedFeeding` (`time: Date`, `items: [MappedFeedItem]`, `note: String?`); `struct MappedPoop` (`timestamp: Date`, `tagIDs: [UUID]`, `tagNames: [String]`, `note: String?`); `struct MappedHealth` (`timestamp: Date`, `note: String`); `struct MappedRecords` (`feedDay`, `feedings`, `poop`, `health`, `warnings`, all `var`, plus `var isEmpty: Bool`); `enum DraftMapper` with `static func map(draft:animal:today:existingDay:tags:now:calendar:) -> MappedRecords`, `static func parseTime(_:on:calendar:) -> Date?`, `static func number(_:) -> String`, `static func trimmedOrNil(_:) -> String?`.

- [ ] **Step 1: Write the failing test**

`AppTests/DraftMapperTests.swift`:
```swift
import XCTest
@testable import AnimalTracker

final class DraftMapperTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    /// 2026-09-18 00:00 UTC
    private let today = Date(timeIntervalSince1970: 1_789_603_200)
    /// 2026-09-18 07:05 UTC
    private let now = Date(timeIntervalSince1970: 1_789_628_700)

    private let normalTag = CheckInTagOption(id: UUID(), name: "normal")
    private let softTag = CheckInTagOption(id: UUID(), name: "soft")

    private func horse(tracksOutdoorTime: Bool = true) -> AnimalSnapshot {
        AnimalSnapshot(id: UUID(), name: "Juniper", species: "horse",
                       tracksOutdoorTime: tracksOutdoorTime, isArchived: false, sortOrder: 0)
    }

    private func map(_ draft: CheckInDraft, animal: AnimalSnapshot? = nil,
                     existing: ExistingFeedDaySnapshot? = nil) -> MappedRecords {
        DraftMapper.map(draft: draft, animal: animal ?? horse(), today: today, existingDay: existing,
                        tags: [normalTag, softTag], now: now, calendar: calendar)
    }

    func testEmptyDraftProducesNothing() {
        let records = map(.empty)
        XCTAssertTrue(records.isEmpty)
        XCTAssertEqual(records.warnings, [])
    }

    func testFeedDayFieldsAreCarriedWithTodaysDate() {
        let records = map(CheckInDraft(feedDay: .init(outdoorHours: 6.5, outdoorAreaAcres: 2, note: " muddy ")))
        let day = records.feedDay
        XCTAssertEqual(day?.date, today)
        XCTAssertEqual(day?.outdoorHours, 6.5)
        XCTAssertEqual(day?.outdoorAreaAcres, 2)
        XCTAssertEqual(day?.note, "muddy")
        XCTAssertEqual(records.warnings, [])
    }

    func testOutOfRangeNumbersAreClampedAndFlagged() {
        let records = map(CheckInDraft(feedDay: .init(outdoorHours: 30, outdoorAreaAcres: -4)))
        XCTAssertEqual(records.feedDay?.outdoorHours, 24)
        XCTAssertEqual(records.feedDay?.outdoorAreaAcres, 0)
        XCTAssertEqual(records.warnings, [
            "Outdoor hours 30 is outside 0 to 24 and was clamped to 24.",
            "Outdoor area -4 is negative and was clamped to 0.",
        ])
    }

    func testOutdoorFieldsAreDroppedWhenTheAnimalDoesNotTrackThem() {
        let records = map(CheckInDraft(feedDay: .init(outdoorHours: 6, outdoorAreaAcres: 2, note: "fine")),
                          animal: horse(tracksOutdoorTime: false))
        XCTAssertNil(records.feedDay?.outdoorHours)
        XCTAssertNil(records.feedDay?.outdoorAreaAcres)
        XCTAssertEqual(records.feedDay?.note, "fine")
        XCTAssertEqual(records.warnings,
                       ["Juniper does not track outdoor time, so the outdoor hours and area were dropped."])
    }

    func testExistingDayOverwritesAreCalledOut() {
        let existing = ExistingFeedDaySnapshot(outdoorHours: 4, outdoorAreaAcres: 2, note: "dry")
        let records = map(CheckInDraft(feedDay: .init(outdoorHours: 6, outdoorAreaAcres: 2, note: "muddy")),
                          existing: existing)
        XCTAssertEqual(records.warnings, [
            "Today's feed day already records 4 outdoor hours; saving overwrites it with 6.",
            "Today's feed day already has a note; saving overwrites it.",
        ])
    }

    func testFeedingTimeIsParsedAndNullTimeFallsBackToTheCheckInStart() {
        let draft = CheckInDraft(feedings: [
            .init(time: "07:30", items: [.init(category: "forage", type: "hay", amount: 2, unit: "flakes")]),
            .init(time: nil, items: [.init(category: "treat", type: "carrot", amount: 1, unit: "each")]),
        ])
        let records = map(draft)
        XCTAssertEqual(records.feedings.count, 2)
        XCTAssertEqual(records.feedings[0].time, calendar.date(bySettingHour: 7, minute: 30, second: 0, of: today))
        XCTAssertEqual(records.feedings[1].time, now)
        XCTAssertEqual(records.warnings, [])
    }

    func testUnreadableTimeFallsBackAndIsFlagged() {
        let records = map(CheckInDraft(feedings: [.init(time: "breakfast", items: [])]))
        XCTAssertEqual(records.feedings[0].time, now)
        XCTAssertEqual(records.warnings,
                       ["Feeding 1 had an unreadable time \"breakfast\"; the check-in start time was used."])
    }

    func testItemsAreNormalizedAndBadOnesDropped() {
        let draft = CheckInDraft(feedings: [.init(time: "07:00", items: [
            .init(category: "forage", type: " hay ", amount: 2, unit: " flakes "),
            .init(category: "supplement", type: "MSM", amount: nil, unit: nil),
            .init(category: "food", type: "grain", amount: -3, unit: "lb"),
            .init(category: "dessert", type: "cake", amount: 1, unit: "slice"),
            .init(category: "food", type: "   ", amount: 1, unit: "cup"),
        ])])
        let items = map(draft).feedings[0].items
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0], MappedFeedItem(category: .forage, type: "hay", amount: 2, unit: "flakes", sortOrder: 0))
        XCTAssertEqual(items[1], MappedFeedItem(category: .supplement, type: "MSM", amount: 0, unit: "", sortOrder: 1))
        XCTAssertEqual(items[2], MappedFeedItem(category: .food, type: "grain", amount: 0, unit: "lb", sortOrder: 2))
        XCTAssertEqual(map(draft).warnings, [
            "grain amount -3 is negative and was clamped to 0.",
            "Feeding 1 had an unknown category \"dessert\" and that item was dropped.",
            "Feeding 1 had an item with no type and it was dropped.",
        ])
    }

    func testUnknownPoopTagsAreDroppedAndListed() {
        let records = map(CheckInDraft(poop: .init(tags: ["Normal", "sparkly", "normal", "beige"], note: "fine")))
        let poop = records.poop
        XCTAssertEqual(poop?.tagIDs, [normalTag.id])
        XCTAssertEqual(poop?.tagNames, ["normal"])
        XCTAssertEqual(poop?.note, "fine")
        XCTAssertEqual(poop?.timestamp, now)
        XCTAssertEqual(records.warnings, ["unrecognized: sparkly, beige"])
    }

    func testPoopWithNoRecognizedTagIsDroppedAndHealthNoteIsKept() {
        let records = map(CheckInDraft(poop: .init(tags: ["sparkly"], note: "odd"),
                                       health: .init(note: "  slightly off food  ")))
        XCTAssertNil(records.poop)
        XCTAssertEqual(records.warnings, [
            "unrecognized: sparkly",
            "The poop note had no recognized tag, so no poop observation was created.",
        ])
        XCTAssertEqual(records.health?.note, "slightly off food")
        XCTAssertEqual(records.health?.timestamp, now)
        XCTAssertNil(map(CheckInDraft(health: .init(note: "   "))).health)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test-app.sh`
Expected: build errors, `DraftMapper`, `MappedRecords` and `CheckInTagOption` not found.

- [ ] **Step 3: Implement**

`App/CheckIn/DraftMapper.swift`:
```swift
import Foundation

/// A poop tag the mapper may match against, without importing SwiftData.
struct CheckInTagOption: Equatable, Identifiable {
    let id: UUID
    let name: String

    init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

/// Today's feed day as it already stands, so the mapper can warn about overwrites.
struct ExistingFeedDaySnapshot: Equatable {
    let outdoorHours: Double?
    let outdoorAreaAcres: Double?
    let note: String?

    init(outdoorHours: Double? = nil, outdoorAreaAcres: Double? = nil, note: String? = nil) {
        self.outdoorHours = outdoorHours
        self.outdoorAreaAcres = outdoorAreaAcres
        self.note = note
    }
}

struct MappedFeedDay: Equatable {
    var date: Date
    var outdoorHours: Double?
    var outdoorAreaAcres: Double?
    var note: String?
}

struct MappedFeedItem: Equatable {
    var category: FeedCategory
    var type: String
    var amount: Double
    var unit: String
    var sortOrder: Int
}

struct MappedFeeding: Equatable {
    var time: Date
    var items: [MappedFeedItem]
    var note: String?
}

struct MappedPoop: Equatable {
    var timestamp: Date
    var tagIDs: [UUID]
    var tagNames: [String]
    var note: String?
}

struct MappedHealth: Equatable {
    var timestamp: Date
    var note: String
}

/// What Review shows and Save commits, plus everything the mapper had to change or drop.
struct MappedRecords: Equatable {
    var feedDay: MappedFeedDay?
    var feedings: [MappedFeeding] = []
    var poop: MappedPoop?
    var health: MappedHealth?
    var warnings: [String] = []

    var isEmpty: Bool { feedDay == nil && feedings.isEmpty && poop == nil && health == nil }
}

enum DraftMapper {
    static func map(draft: CheckInDraft, animal: AnimalSnapshot, today: Date,
                    existingDay: ExistingFeedDaySnapshot?, tags: [CheckInTagOption], now: Date,
                    calendar: Calendar = .current) -> MappedRecords {
        var records = MappedRecords()
        records.feedDay = mapFeedDay(draft: draft, animal: animal, today: today,
                                     existing: existingDay, warnings: &records.warnings)
        records.feedings = mapFeedings(draft: draft, today: today, now: now,
                                       calendar: calendar, warnings: &records.warnings)
        records.poop = mapPoop(draft: draft, tags: tags, now: now, warnings: &records.warnings)
        records.health = mapHealth(draft: draft, now: now)
        return records
    }

    // MARK: - Feed day

    private static func mapFeedDay(draft: CheckInDraft, animal: AnimalSnapshot, today: Date,
                                   existing: ExistingFeedDaySnapshot?, warnings: inout [String]) -> MappedFeedDay? {
        guard let source = draft.feedDay else { return nil }
        var hours = source.outdoorHours
        var acres = source.outdoorAreaAcres

        if !animal.tracksOutdoorTime, hours != nil || acres != nil {
            warnings.append("\(animal.name) does not track outdoor time, so the outdoor hours and area were dropped.")
            hours = nil
            acres = nil
        }
        if let value = hours, value < 0 || value > 24 {
            let clamped = min(max(value, 0), 24)
            warnings.append("Outdoor hours \(number(value)) is outside 0 to 24 and was clamped to \(number(clamped)).")
            hours = clamped
        }
        if let value = acres, value < 0 {
            warnings.append("Outdoor area \(number(value)) is negative and was clamped to 0.")
            acres = 0
        }

        let note = trimmedOrNil(source.note)
        guard hours != nil || acres != nil || note != nil else { return nil }

        if let existing {
            if let new = hours, let old = existing.outdoorHours, old != new {
                warnings.append("Today's feed day already records \(number(old)) outdoor hours; saving overwrites it with \(number(new)).")
            }
            if let new = acres, let old = existing.outdoorAreaAcres, old != new {
                warnings.append("Today's feed day already records \(number(old)) acres; saving overwrites it with \(number(new)).")
            }
            if let new = note, let old = trimmedOrNil(existing.note), old != new {
                warnings.append("Today's feed day already has a note; saving overwrites it.")
            }
        }
        return MappedFeedDay(date: today, outdoorHours: hours, outdoorAreaAcres: acres, note: note)
    }

    // MARK: - Feedings

    private static func mapFeedings(draft: CheckInDraft, today: Date, now: Date, calendar: Calendar,
                                    warnings: inout [String]) -> [MappedFeeding] {
        var result: [MappedFeeding] = []
        for (position, source) in draft.feedings.enumerated() {
            let label = position + 1
            var time = now
            if let raw = trimmedOrNil(source.time) {
                if let parsed = parseTime(raw, on: today, calendar: calendar) {
                    time = parsed
                } else {
                    warnings.append("Feeding \(label) had an unreadable time \"\(raw)\"; the check-in start time was used.")
                }
            }

            var items: [MappedFeedItem] = []
            for item in source.items {
                guard let category = FeedCategory(rawValue: item.category) else {
                    warnings.append("Feeding \(label) had an unknown category \"\(item.category)\" and that item was dropped.")
                    continue
                }
                guard let type = trimmedOrNil(item.type) else {
                    warnings.append("Feeding \(label) had an item with no type and it was dropped.")
                    continue
                }
                var amount = item.amount ?? 0
                if amount < 0 {
                    warnings.append("\(type) amount \(number(amount)) is negative and was clamped to 0.")
                    amount = 0
                }
                items.append(MappedFeedItem(category: category, type: type, amount: amount,
                                            unit: trimmedOrNil(item.unit) ?? "", sortOrder: items.count))
            }
            result.append(MappedFeeding(time: time, items: items, note: trimmedOrNil(source.note)))
        }
        return result
    }

    /// Local "HH:mm" placed on the check-in's day. Anything else returns nil.
    static func parseTime(_ text: String, on day: Date, calendar: Calendar) -> Date? {
        let parts = text.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
    }

    // MARK: - Poop and health

    private static func mapPoop(draft: CheckInDraft, tags: [CheckInTagOption], now: Date,
                                warnings: inout [String]) -> MappedPoop? {
        guard let source = draft.poop else { return nil }
        var ids: [UUID] = []
        var names: [String] = []
        var unknown: [String] = []

        for raw in source.tags {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            if let match = tags.first(where: { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }) {
                if !ids.contains(match.id) {
                    ids.append(match.id)
                    names.append(match.name)
                }
            } else if !unknown.contains(name) {
                unknown.append(name)
            }
        }
        if !unknown.isEmpty {
            warnings.append("unrecognized: \(unknown.joined(separator: ", "))")
        }

        let note = trimmedOrNil(source.note)
        guard !ids.isEmpty else {
            if note != nil {
                warnings.append("The poop note had no recognized tag, so no poop observation was created.")
            }
            return nil
        }
        return MappedPoop(timestamp: now, tagIDs: ids, tagNames: names, note: note)
    }

    private static func mapHealth(draft: CheckInDraft, now: Date) -> MappedHealth? {
        guard let note = trimmedOrNil(draft.health?.note) else { return nil }
        return MappedHealth(timestamp: now, note: note)
    }

    // MARK: - Helpers

    /// "6" not "6.0", "6.5" stays "6.5". Used in warning copy.
    static func number(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e9 { return String(Int(value)) }
        return String(format: "%g", value)
    }

    static func trimmedOrNil(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `scripts/test-app.sh`
Expected: the ten `DraftMapperTests` pass.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(checkin): DraftMapper turning a draft into mapped records with clamp, unknown-tag and overwrite warnings

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: Transcriber protocol, SpeechTranscriber, scripted double, QuestionSpeaker

Adds 4 tests. No SwiftData, no network. Only the scripted double is tested; the live speech and TTS wrappers are verified by hand on the simulator, as the spec's testing section allows.

**Files:**
- Create: `App/CheckIn/Transcriber.swift`, `App/CheckIn/SpeechTranscriber.swift`, `App/CheckIn/QuestionSpeaker.swift`
- Test: `AppTests/TranscriberTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `@MainActor protocol Transcriber: AnyObject` with `var isAvailable: Bool { get }`, `var transcript: String { get }`, `func requestAuthorization() async -> Bool`, `func start(onUpdate: @escaping (String) -> Void) throws`, `func stop()`; `enum TranscriberError: LocalizedError` with `.unavailable`, `.notAuthorized`, `.audioSessionFailed(String)`; `@MainActor final class ScriptedTranscriber: Transcriber` with `init(partials: [String], authorized: Bool = true, available: Bool = true)`, `var startCount: Int`, `var stopCount: Int`, `func emitNextPartial()`, `func emitAll()`; `@MainActor final class SpeechTranscriber: Transcriber`; `@MainActor final class QuestionSpeaker` with `func speak(_ text: String)`, `func stop()`.

- [ ] **Step 1: Write the failing test**

`AppTests/TranscriberTests.swift`:
```swift
import XCTest
@testable import AnimalTracker

@MainActor
final class TranscriberTests: XCTestCase {
    func testScriptedTranscriberStreamsPartialsInOrder() throws {
        let transcriber = ScriptedTranscriber(partials: ["six", "six hours", "six hours out"])
        var seen: [String] = []
        try transcriber.start { seen.append($0) }
        transcriber.emitAll()
        XCTAssertEqual(seen, ["six", "six hours", "six hours out"])
        XCTAssertEqual(transcriber.transcript, "six hours out")
        XCTAssertEqual(transcriber.startCount, 1)
    }

    func testEmitNextPartialAdvancesOneStepAtATime() throws {
        let transcriber = ScriptedTranscriber(partials: ["a", "a b"])
        var seen: [String] = []
        try transcriber.start { seen.append($0) }
        transcriber.emitNextPartial()
        XCTAssertEqual(seen, ["a"])
        XCTAssertEqual(transcriber.transcript, "a")
        transcriber.emitNextPartial()
        transcriber.emitNextPartial()
        XCTAssertEqual(seen, ["a", "a b"])
    }

    func testStopCountsAndRestartClearsTheTranscript() throws {
        let transcriber = ScriptedTranscriber(partials: ["hello"])
        try transcriber.start { _ in }
        transcriber.emitAll()
        transcriber.stop()
        XCTAssertEqual(transcriber.stopCount, 1)
        XCTAssertEqual(transcriber.transcript, "hello")
        try transcriber.start { _ in }
        XCTAssertEqual(transcriber.transcript, "")
        XCTAssertEqual(transcriber.startCount, 2)
    }

    func testUnavailableTranscriberThrowsAndUnauthorizedReturnsFalse() async throws {
        let unavailable = ScriptedTranscriber(partials: ["x"], available: false)
        XCTAssertFalse(unavailable.isAvailable)
        XCTAssertThrowsError(try unavailable.start { _ in }) { error in
            XCTAssertEqual((error as? TranscriberError), .unavailable)
        }
        let denied = ScriptedTranscriber(partials: ["x"], authorized: false)
        let granted = await denied.requestAuthorization()
        XCTAssertFalse(granted)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test-app.sh`
Expected: build errors, `Transcriber`, `TranscriberError` and `ScriptedTranscriber` not found.

- [ ] **Step 3: Implement the protocol and the double**

`App/CheckIn/Transcriber.swift`:
```swift
import Foundation

@MainActor
protocol Transcriber: AnyObject {
    var isAvailable: Bool { get }
    /// The best transcript so far. Updated live while recording.
    var transcript: String { get }
    func requestAuthorization() async -> Bool
    func start(onUpdate: @escaping (String) -> Void) throws
    func stop()
}

enum TranscriberError: LocalizedError, Equatable {
    case unavailable
    case notAuthorized
    case audioSessionFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Speech recognition is not available on this device right now. Type your check-in instead."
        case .notAuthorized:
            return "AnimalTracker needs microphone and speech access to listen. Allow them in Settings, or type your check-in instead."
        case .audioSessionFailed(let detail):
            return "Could not start the microphone: \(detail)"
        }
    }
}

/// Test double: replays a canned list of partial results on demand.
@MainActor
final class ScriptedTranscriber: Transcriber {
    private let partials: [String]
    private let authorized: Bool
    private let available: Bool
    private var cursor = 0
    private var onUpdate: ((String) -> Void)?

    private(set) var transcript = ""
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(partials: [String], authorized: Bool = true, available: Bool = true) {
        self.partials = partials
        self.authorized = authorized
        self.available = available
    }

    var isAvailable: Bool { available }

    func requestAuthorization() async -> Bool { authorized }

    func start(onUpdate: @escaping (String) -> Void) throws {
        guard available else { throw TranscriberError.unavailable }
        guard authorized else { throw TranscriberError.notAuthorized }
        startCount += 1
        cursor = 0
        transcript = ""
        self.onUpdate = onUpdate
    }

    func stop() {
        stopCount += 1
    }

    /// Deliver the next scripted partial, if any remain.
    func emitNextPartial() {
        guard cursor < partials.count else { return }
        transcript = partials[cursor]
        cursor += 1
        onUpdate?(transcript)
    }

    func emitAll() {
        while cursor < partials.count { emitNextPartial() }
    }
}
```

- [ ] **Step 4: Implement the live speech and speech-synthesis wrappers**

`App/CheckIn/SpeechTranscriber.swift`:
```swift
import AVFoundation
import Foundation
import Speech

/// Live on-device dictation. On-device recognition is requested whenever the recognizer supports
/// it, so the audio never leaves the phone; only the resulting text is sent to Anthropic.
@MainActor
final class SpeechTranscriber: Transcriber {
    private let recognizer = SFSpeechRecognizer(locale: Locale.current)
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var onUpdate: ((String) -> Void)?

    private(set) var transcript = ""

    var isAvailable: Bool { recognizer?.isAvailable ?? false }

    func requestAuthorization() async -> Bool {
        let speechStatus: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speechStatus == .authorized else { return false }
        return await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
    }

    func start(onUpdate: @escaping (String) -> Void) throws {
        stop()
        guard let recognizer, recognizer.isAvailable else { throw TranscriberError.unavailable }
        self.onUpdate = onUpdate
        transcript = ""

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw TranscriberError.audioSessionFailed(error.localizedDescription)
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.request = nil
            throw TranscriberError.audioSessionFailed(error.localizedDescription)
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                Task { @MainActor in
                    self.transcript = text
                    self.onUpdate?(text)
                }
            }
            if error != nil || (result?.isFinal ?? false) {
                Task { @MainActor in self.stop() }
            }
        }
    }

    func stop() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
```

`App/CheckIn/QuestionSpeaker.swift`:
```swift
import AVFoundation
import Foundation

/// Reads the assistant's follow-up question aloud when `speakQuestions` is on.
@MainActor
final class QuestionSpeaker {
    private let synthesizer = AVSpeechSynthesizer()

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        stop()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: .duckOthers)
        try? AVAudioSession.sharedInstance().setActive(true)
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier)
            ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    }
}
```

- [ ] **Step 5: Run to verify pass**

Run: `scripts/test-app.sh`
Expected: the four `TranscriberTests` pass.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(checkin): Transcriber protocol, on-device SpeechTranscriber, scripted double and QuestionSpeaker

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 9: CheckInSession state machine

Adds 10 tests. No SwiftData, no network: every test drives `ScriptedClaudeClient` and `ScriptedTranscriber`.

**Files:**
- Create: `App/CheckIn/CheckInSession.swift`
- Test: `AppTests/CheckInSessionTests.swift`

**Interfaces:**
- Consumes: `ClaudeClient`, `ScriptedClaudeClient`, `ClaudeClientError`, `ClaudeMessage`, `ClaudeResponse` (Tasks 3-5), `Transcriber`, `TranscriberError` (Task 8), `CheckInDraft` (Task 2), `TurnRole` from Plan A.
- Produces: `@MainActor @Observable final class CheckInSession` with `enum State { idle, recording, extracting, asking, reviewing, saved, discarded, failed }`, `struct SessionTurn: Equatable, Identifiable` (`id, role, text, timestamp, draftJSON`), `init(client:transcriber:system:schema:questionCap:apiKeyProvider:clock:)`, readable `state, turns, draft, currentQuestion, questionCount, inputTokens, outputTokens, failureReason, startedAt`, writable `liveTranscript`, and `func startRecording() throws`, `func stopRecording()`, `func submit() async`, `func finish()`, `func markSaved()`, `func markDiscarded()`, `func markFailed(_ reason: String)`, `static func isEndPhrase(_ text: String) -> Bool`, `static let endPhrases: Set<String>`, `static let brevityPrompt: String`.

- [ ] **Step 1: Write the failing test**

`AppTests/CheckInSessionTests.swift`:
```swift
import XCTest
@testable import AnimalTracker

@MainActor
final class CheckInSessionTests: XCTestCase {
    private func response(_ draftJSON: String, stop: ClaudeResponse.StopReason = .endTurn,
                          input: Int = 100, output: Int = 20) -> ClaudeResponse {
        ClaudeResponse(stopReason: stop, jsonText: draftJSON, inputTokens: input, outputTokens: output)
    }

    private func session(_ results: [Result<ClaudeResponse, Error>],
                         transcriber: ScriptedTranscriber = ScriptedTranscriber(partials: []),
                         cap: Int = 8, key: String? = "sk-ant-test") -> (CheckInSession, ScriptedClaudeClient) {
        let client = ScriptedClaudeClient(results)
        let session = CheckInSession(client: client, transcriber: transcriber, system: "SYSTEM",
                                     schema: CheckInSchema.dictionary, questionCap: cap,
                                     apiKeyProvider: { key },
                                     clock: { Date(timeIntervalSince1970: 1_789_628_700) })
        return (session, client)
    }

    private let question = #"{"feedDay":null,"feedings":[],"poop":null,"health":null,"missing":["forage"],"nextQuestion":"What forage did she get?","done":false}"#
    private let finished = #"{"feedDay":{"outdoorHours":6,"outdoorAreaAcres":null,"note":null},"feedings":[],"poop":null,"health":null,"missing":[],"nextQuestion":null,"done":true}"#

    func testStartsIdleAndRecordsThroughTheTranscriber() throws {
        let transcriber = ScriptedTranscriber(partials: ["six", "six hours out"])
        let (session, _) = session([], transcriber: transcriber)
        XCTAssertEqual(session.state, .idle)
        try session.startRecording()
        XCTAssertEqual(session.state, .recording)
        transcriber.emitAll()
        XCTAssertEqual(session.liveTranscript, "six hours out")
        session.stopRecording()
        XCTAssertEqual(transcriber.stopCount, 1)
    }

    func testAnsweredQuestionMovesToAskingAndCountsTokens() async {
        let (session, client) = session([.success(response(question))])
        session.liveTranscript = "She was out six hours."
        await session.submit()
        XCTAssertEqual(session.state, .asking)
        XCTAssertEqual(session.currentQuestion, "What forage did she get?")
        XCTAssertEqual(session.questionCount, 1)
        XCTAssertEqual(session.inputTokens, 100)
        XCTAssertEqual(session.outputTokens, 20)
        XCTAssertEqual(session.turns.map(\.role), [.user, .assistant])
        XCTAssertEqual(session.turns[0].text, "She was out six hours.")
        XCTAssertEqual(session.turns[1].draftJSON, question)
        XCTAssertEqual(session.liveTranscript, "")
        XCTAssertEqual(client.sentSystems, ["SYSTEM"])
        XCTAssertEqual(client.sentMessages[0], [.user("She was out six hours.")])
    }

    func testFullHistoryIsResentOnEveryTurn() async {
        let (session, client) = session([.success(response(question)), .success(response(finished))])
        session.liveTranscript = "six hours out"
        await session.submit()
        session.liveTranscript = "two flakes of hay"
        await session.submit()
        XCTAssertEqual(session.state, .reviewing)
        XCTAssertEqual(session.draft.feedDay?.outdoorHours, 6)
        XCTAssertEqual(session.inputTokens, 200)
        XCTAssertEqual(client.sentMessages[1],
                       [.user("six hours out"), .assistant(question), .user("two flakes of hay")])
    }

    func testDoneDraftEndsTheLoop() async {
        let (session, _) = session([.success(response(finished))])
        session.liveTranscript = "that's everything for today"
        await session.submit()
        XCTAssertEqual(session.state, .reviewing)
        XCTAssertNil(session.currentQuestion)
        XCTAssertNil(session.failureReason)
    }

    func testEndWordsSkipTheRequestEntirely() async {
        for phrase in ["done", "Done!", "skip", "That's all.", "  thats all  "] {
            let (session, client) = session([.success(response(question))])
            session.liveTranscript = phrase
            await session.submit()
            XCTAssertEqual(session.state, .reviewing, phrase)
            XCTAssertEqual(client.callCount, 0, phrase)
            XCTAssertEqual(session.turns.count, 1, phrase)
        }
        XCTAssertFalse(CheckInSession.isEndPhrase("I'm done feeding her"))
        XCTAssertFalse(CheckInSession.isEndPhrase(""))
    }

    func testQuestionCapStopsTheLoop() async {
        let script = Array(repeating: Result<ClaudeResponse, Error>.success(response(question)), count: 4)
        let (session, _) = session(script, cap: 2)
        for _ in 0..<3 {
            session.liveTranscript = "more information"
            await session.submit()
        }
        XCTAssertEqual(session.questionCount, 2)
        XCTAssertEqual(session.state, .reviewing)
        XCTAssertNil(session.currentQuestion)
    }

    func testMaxTokensRetriesOnceAskingForBrevity() async {
        let (session, client) = session([.success(response("{\"feedDay\":", stop: .maxTokens)),
                                         .success(response(question))])
        session.liveTranscript = "a very long story"
        await session.submit()
        XCTAssertEqual(client.callCount, 2)
        XCTAssertEqual(client.sentMessages[1].last, .user(CheckInSession.brevityPrompt))
        XCTAssertEqual(session.state, .asking)
        XCTAssertNil(session.failureReason)
    }

    func testMaxTokensTwiceOpensReviewWithAnEmptyDraft() async {
        let truncated = Result<ClaudeResponse, Error>.success(response("{\"feedDay\":", stop: .maxTokens))
        let (session, _) = session([truncated, truncated])
        session.liveTranscript = "a very long story"
        await session.submit()
        XCTAssertEqual(session.state, .reviewing)
        XCTAssertEqual(session.draft, .empty)
        XCTAssertEqual(session.failureReason,
                       "The assistant's answer was cut off twice. Fill the records in by hand.")
        XCTAssertEqual(session.turns.first?.text, "a very long story")
    }

    func testRefusalAndUnparseableJSONBothOpenReviewEmptyAndKeepTheTranscript() async {
        let refusal = ClaudeResponse(stopReason: .refusal, jsonText: nil, inputTokens: 5, outputTokens: 0,
                                     refusalCategory: "cyber", refusalExplanation: "Declined.")
        let (refused, _) = session([.success(refusal)])
        refused.liveTranscript = "six hours out"
        await refused.submit()
        XCTAssertEqual(refused.state, .reviewing)
        XCTAssertEqual(refused.draft, .empty)
        XCTAssertEqual(refused.failureReason, "The assistant declined to answer this check-in: Declined.")
        XCTAssertEqual(refused.turns.first?.text, "six hours out")

        let (garbled, _) = session([.success(response("not json at all"))])
        garbled.liveTranscript = "six hours out"
        await garbled.submit()
        XCTAssertEqual(garbled.state, .reviewing)
        XCTAssertEqual(garbled.draft, .empty)
        XCTAssertEqual(garbled.failureReason,
                       "The assistant's answer was not valid JSON. Fill the records in by hand.")
    }

    func testNetworkFailureAndMissingKeyReachReviewAndTerminalsStick() async {
        let (offline, _) = session([.failure(ClaudeClientError.connection("offline"))])
        offline.liveTranscript = "six hours out"
        await offline.submit()
        XCTAssertEqual(offline.state, .reviewing)
        XCTAssertEqual(offline.failureReason, "Could not reach Anthropic: offline")

        let (noKey, client) = session([.success(response(question))], key: nil)
        noKey.liveTranscript = "six hours out"
        await noKey.submit()
        XCTAssertEqual(client.callCount, 0)
        XCTAssertEqual(noKey.state, .reviewing)
        XCTAssertEqual(noKey.failureReason, ClaudeClientError.missingAPIKey.errorDescription)

        noKey.markSaved()
        XCTAssertEqual(noKey.state, .saved)
        noKey.markDiscarded()
        XCTAssertEqual(noKey.state, .discarded)
        noKey.markFailed("save failed")
        XCTAssertEqual(noKey.state, .failed)
        XCTAssertEqual(noKey.failureReason, "save failed")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test-app.sh`
Expected: build errors, `CheckInSession` not found.

- [ ] **Step 3: Implement**

`App/CheckIn/CheckInSession.swift`:
```swift
import Foundation
import Observation

/// The check-in conversation as a state machine. It knows nothing about SwiftData, URLSession,
/// SFSpeechRecognizer or SwiftUI: only the ClaudeClient and Transcriber protocols.
@MainActor
@Observable
final class CheckInSession {
    enum State: Equatable {
        case idle
        case recording
        case extracting
        case asking
        case reviewing
        case saved
        case discarded
        case failed
    }

    struct SessionTurn: Equatable, Identifiable {
        let id: UUID
        let role: TurnRole
        let text: String
        let timestamp: Date
        let draftJSON: String?
    }

    private let client: ClaudeClient
    private let transcriber: Transcriber
    private let system: String
    private let schema: [String: Any]
    private let questionCap: Int
    private let apiKeyProvider: () -> String?
    private let clock: () -> Date

    private(set) var state: State = .idle
    private(set) var turns: [SessionTurn] = []
    private(set) var draft: CheckInDraft = .empty
    private(set) var currentQuestion: String?
    private(set) var questionCount = 0
    private(set) var inputTokens = 0
    private(set) var outputTokens = 0
    /// Set when the conversation could not be completed. Review still opens; the stored check-in
    /// is marked failed with this reason.
    private(set) var failureReason: String?
    private(set) var startedAt: Date

    /// The editable live transcript, or the typed fallback text.
    var liveTranscript = ""

    private var didRetryForBrevity = false

    init(client: ClaudeClient, transcriber: Transcriber, system: String, schema: [String: Any],
         questionCap: Int, apiKeyProvider: @escaping () -> String?,
         clock: @escaping () -> Date = Date.init) {
        self.client = client
        self.transcriber = transcriber
        self.system = system
        self.schema = schema
        self.questionCap = questionCap
        self.apiKeyProvider = apiKeyProvider
        self.clock = clock
        self.startedAt = clock()
    }

    // MARK: - End words

    static let endPhrases: Set<String> = ["done", "skip", "thats all"]

    static let brevityPrompt = "Your last answer was cut off. Reply with the JSON object only, keep every note under 12 words, and ask at most one short question."

    /// True when the whole utterance is an end word, not when one appears inside a sentence.
    static func isEndPhrase(_ text: String) -> Bool {
        let stripped = text.lowercased()
            .components(separatedBy: CharacterSet.punctuationCharacters.union(.symbols))
            .joined()
        let collapsed = stripped.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return endPhrases.contains(collapsed)
    }

    // MARK: - Recording

    func startRecording() throws {
        failureReason = nil
        liveTranscript = ""
        state = .recording
        try transcriber.start { [weak self] text in
            self?.liveTranscript = text
        }
    }

    func stopRecording() {
        transcriber.stop()
    }

    // MARK: - The loop

    /// Send whatever is in `liveTranscript` as the next user turn.
    func submit() async {
        let text = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        transcriber.stop()
        appendTurn(role: .user, text: text, draftJSON: nil)
        liveTranscript = ""
        currentQuestion = nil
        if Self.isEndPhrase(text) {
            state = .reviewing
            return
        }
        await extract()
    }

    /// The Finish button: keep anything already dictated, then go to Review.
    func finish() {
        transcriber.stop()
        let text = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            appendTurn(role: .user, text: text, draftJSON: nil)
            liveTranscript = ""
        }
        currentQuestion = nil
        state = .reviewing
    }

    func markSaved() { state = .saved }

    func markDiscarded() { state = .discarded }

    func markFailed(_ reason: String) {
        failureReason = reason
        state = .failed
    }

    // MARK: - Private

    private func extract() async {
        guard let apiKey = apiKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty else {
            failToReview(ClaudeClientError.missingAPIKey.errorDescription ?? "No API key.")
            return
        }
        state = .extracting

        let response: ClaudeResponse
        do {
            response = try await client.send(system: system, messages: apiMessages(),
                                             schema: schema, apiKey: apiKey)
        } catch let error as ClaudeClientError {
            failToReview(error.errorDescription ?? "The request failed.")
            return
        } catch {
            failToReview(error.localizedDescription)
            return
        }

        inputTokens += response.inputTokens
        outputTokens += response.outputTokens

        switch response.stopReason {
        case .refusal:
            let detail = response.refusalExplanation.map { ": \($0)" } ?? "."
            failToReview("The assistant declined to answer this check-in\(detail)")

        case .maxTokens:
            if didRetryForBrevity {
                failToReview("The assistant's answer was cut off twice. Fill the records in by hand.")
            } else {
                didRetryForBrevity = true
                appendTurn(role: .user, text: Self.brevityPrompt, draftJSON: nil)
                await extract()
            }

        case .endTurn, .other:
            guard let json = response.jsonText, let decoded = CheckInDraft.decode(json) else {
                failToReview("The assistant's answer was not valid JSON. Fill the records in by hand.")
                return
            }
            appendTurn(role: .assistant, text: json, draftJSON: json)
            draft = decoded
            didRetryForBrevity = false
            if decoded.done || decoded.nextQuestion == nil || questionCount >= questionCap {
                currentQuestion = nil
                state = .reviewing
            } else {
                questionCount += 1
                currentQuestion = decoded.nextQuestion
                state = .asking
            }
        }
    }

    private func failToReview(_ reason: String) {
        failureReason = reason
        draft = .empty
        currentQuestion = nil
        state = .reviewing
    }

    private func apiMessages() -> [ClaudeMessage] {
        turns.map { ClaudeMessage(role: $0.role == .user ? "user" : "assistant", text: $0.text) }
    }

    private func appendTurn(role: TurnRole, text: String, draftJSON: String?) {
        turns.append(SessionTurn(id: UUID(), role: role, text: text,
                                 timestamp: clock(), draftJSON: draftJSON))
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `scripts/test-app.sh`
Expected: the ten `CheckInSessionTests` pass.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(checkin): CheckInSession observable state machine with question cap, end words and brevity retry

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 10: CheckInCommitter, the check-in sheet, and the real mic entry point

Adds 3 tests (the only ones in this plan that touch SwiftData).

**Files:**
- Create: `App/CheckIn/CheckInCommitter.swift`, `App/Views/CheckIn/CheckInSheetView.swift`, `App/Views/CheckIn/CheckInReviewView.swift`
- Modify: `App/AnimalSwitcher.swift` (replace the `OralCheckInEntry` placeholder)
- Test: `AppTests/CheckInCommitterTests.swift`

**Interfaces:**
- Consumes: `OralCheckIn`, `CheckInTurn` (Task 1), `MappedRecords`, `CheckInTagOption`, `ExistingFeedDaySnapshot`, `DraftMapper` (Task 7), `CheckInSession` (Task 9), `SystemPromptBuilder`, `SystemPromptInput` (Task 6), `CheckInSchema` (Task 2), `LiveClaudeClient` (Task 5), `SpeechTranscriber`, `QuestionSpeaker` (Task 8), `ClaudeRequestBuilder.model` (Task 4); from earlier plans: `Animal`, `AnimalSnapshot`, `KeychainStore`, `ColorPalette`, `FeedDay`, `Feeding`, `FeedItem`, `FeedCategory`, `PoopTag`, `PoopObservation`, `HealthCheckIn`, `AACButton`, `CheckInStatus`, `TurnRole`, `\.selectedAnimal`.
- Produces: `@MainActor enum CheckInCommitter` with `static func start(animal:startedAt:context:) -> OralCheckIn`, `static func syncTurns(_:to:context:)`, `static func existingFeedDay(for:on:context:calendar:) throws -> FeedDay?`, `static func commit(records:today:checkIn:animal:tags:inputTokens:outputTokens:endedAt:context:calendar:) throws`, `static func close(checkIn:status:reason:endedAt:inputTokens:outputTokens:context:) throws`, `static func encodeIDs(_:) -> String`; `struct CheckInSheetView: View` with `init(animal: Animal)`; `struct CheckInReviewView: View`; a real `struct OralCheckInEntry: View`.

- [ ] **Step 1: Write the failing test**

`AppTests/CheckInCommitterTests.swift`:
```swift
import SwiftData
import XCTest
@testable import AnimalTracker

@MainActor
final class CheckInCommitterTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private let today = Date(timeIntervalSince1970: 1_789_603_200)   // 2026-09-18 00:00 UTC
    private let now = Date(timeIntervalSince1970: 1_789_628_700)     // 2026-09-18 07:05 UTC

    private func fixture() throws -> (ModelContext, Animal, PoopTag) {
        let context = try TestSupport.container().mainContext
        let animal = Animal(name: "Juniper", species: "horse")
        context.insert(animal)
        let tag = PoopTag()
        tag.name = "normal"
        tag.isBuiltIn = true
        context.insert(tag)
        try context.save()
        return (context, animal, tag)
    }

    private func records(tagID: UUID) -> MappedRecords {
        MappedRecords(
            feedDay: MappedFeedDay(date: today, outdoorHours: 6, outdoorAreaAcres: 2, note: "muddy"),
            feedings: [MappedFeeding(time: now, items: [
                MappedFeedItem(category: .forage, type: "hay", amount: 2, unit: "flakes", sortOrder: 0),
                MappedFeedItem(category: .supplement, type: "MSM", amount: 1, unit: "scoop", sortOrder: 1),
            ], note: "ate it all")],
            poop: MappedPoop(timestamp: now, tagIDs: [tagID], tagNames: ["normal"], note: nil),
            health: MappedHealth(timestamp: now, note: "acting normally"),
            warnings: [])
    }

    func testCommitWritesEverythingAndMarksTheCheckInSaved() throws {
        let (context, animal, tag) = try fixture()
        let checkIn = CheckInCommitter.start(animal: animal, startedAt: now, context: context)
        CheckInCommitter.syncTurns([
            .init(id: UUID(), role: .user, text: "six hours out", timestamp: now, draftJSON: nil),
            .init(id: UUID(), role: .assistant, text: "{}", timestamp: now, draftJSON: "{}"),
        ], to: checkIn, context: context)

        try CheckInCommitter.commit(records: records(tagID: tag.id), today: today, checkIn: checkIn,
                                    animal: animal, tags: [tag], inputTokens: 1200, outputTokens: 300,
                                    endedAt: now, context: context, calendar: calendar)

        let days = try context.fetch(FetchDescriptor<FeedDay>())
        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days[0].outdoorHours, 6)
        XCTAssertEqual(days[0].outdoorAreaAcres, 2)
        XCTAssertEqual(days[0].note, "muddy")
        XCTAssertEqual(days[0].animal?.id, animal.id)
        XCTAssertEqual(days[0].feedings?.count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<FeedItem>()).count, 2)
        let observations = try context.fetch(FetchDescriptor<PoopObservation>())
        XCTAssertEqual(observations.count, 1)
        XCTAssertEqual(observations[0].tags?.map(\.name), ["normal"])
        let health = try context.fetch(FetchDescriptor<HealthCheckIn>())
        XCTAssertEqual(health.first?.note, "acting normally")
        XCTAssertEqual(health.first?.animal?.id, animal.id)

        XCTAssertEqual(checkIn.status, .saved)
        XCTAssertEqual(checkIn.endedAt, now)
        XCTAssertEqual(checkIn.inputTokens, 1200)
        XCTAssertEqual(checkIn.outputTokens, 300)
        XCTAssertEqual(checkIn.orderedTurns.map(\.index), [0, 1])
        XCTAssertEqual(checkIn.orderedTurns.map(\.role), [.user, .assistant])
        // 1 feed day + 1 feeding + 2 items + 1 poop + 1 health
        XCTAssertEqual(checkIn.createdRecordIds.count, 6)
        XCTAssertTrue(checkIn.createdRecordIds.contains(days[0].id))
    }

    func testCommitReusesTodaysFeedDayAndOverwritesItsFields() throws {
        let (context, animal, tag) = try fixture()
        let existing = FeedDay()
        existing.date = today
        existing.outdoorHours = 4
        existing.note = "dry"
        existing.animal = animal
        context.insert(existing)
        try context.save()

        XCTAssertEqual(try CheckInCommitter.existingFeedDay(for: animal, on: today, context: context,
                                                            calendar: calendar)?.id, existing.id)

        let checkIn = CheckInCommitter.start(animal: animal, startedAt: now, context: context)
        try CheckInCommitter.commit(records: records(tagID: tag.id), today: today, checkIn: checkIn,
                                    animal: animal, tags: [tag], inputTokens: 0, outputTokens: 0,
                                    endedAt: now, context: context, calendar: calendar)

        let days = try context.fetch(FetchDescriptor<FeedDay>())
        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days[0].id, existing.id)
        XCTAssertEqual(days[0].outdoorHours, 6)
        XCTAssertEqual(days[0].note, "muddy")
        XCTAssertFalse(checkIn.createdRecordIds.contains(existing.id))
    }

    func testCloseKeepsTurnsAndRecordsTheStatusAndReason() throws {
        let (context, animal, _) = try fixture()
        let checkIn = CheckInCommitter.start(animal: animal, startedAt: now, context: context)
        CheckInCommitter.syncTurns([
            .init(id: UUID(), role: .user, text: "six hours out", timestamp: now, draftJSON: nil),
        ], to: checkIn, context: context)

        try CheckInCommitter.close(checkIn: checkIn, status: .failed, reason: "The assistant declined.",
                                   endedAt: now, inputTokens: 10, outputTokens: 0, context: context)
        XCTAssertEqual(checkIn.status, .failed)
        XCTAssertEqual(checkIn.errorMessage, "The assistant declined.")
        XCTAssertEqual(checkIn.turns?.count, 1)
        XCTAssertEqual(checkIn.model, ClaudeRequestBuilder.model)
        XCTAssertEqual(try context.fetch(FetchDescriptor<FeedDay>()).count, 0)
        XCTAssertEqual(CheckInCommitter.encodeIDs([]), "[]")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test-app.sh`
Expected: build errors, `CheckInCommitter` not found.

- [ ] **Step 3: Implement the committer**

`App/CheckIn/CheckInCommitter.swift`:
```swift
import Foundation
import SwiftData

/// The only place in the check-in subsystem that writes to SwiftData. Save commits every mapped
/// record in one transaction so a partial check-in never lands in the store.
@MainActor
enum CheckInCommitter {
    static func start(animal: Animal, startedAt: Date, context: ModelContext) -> OralCheckIn {
        let checkIn = OralCheckIn()
        checkIn.startedAt = startedAt
        checkIn.model = ClaudeRequestBuilder.model
        checkIn.animal = animal
        context.insert(checkIn)
        return checkIn
    }

    /// Appends any turns the store does not have yet, preserving their order.
    static func syncTurns(_ turns: [CheckInSession.SessionTurn], to checkIn: OralCheckIn,
                          context: ModelContext) {
        let alreadyStored = checkIn.turns?.count ?? 0
        guard turns.count > alreadyStored else { return }
        for index in alreadyStored..<turns.count {
            let source = turns[index]
            let row = CheckInTurn()
            row.index = index
            row.role = source.role
            row.text = source.text
            row.timestamp = source.timestamp
            row.draftJSON = source.draftJSON
            row.checkIn = checkIn
            context.insert(row)
        }
    }

    /// Today's feed day for this animal, if it already exists. Fetched by date range and filtered
    /// in Swift, because predicates over an optional relationship are not reliable in iOS 17.
    static func existingFeedDay(for animal: Animal, on day: Date, context: ModelContext,
                                calendar: Calendar = .current) throws -> FeedDay? {
        guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
        let descriptor = FetchDescriptor<FeedDay>(predicate: #Predicate { $0.date >= day && $0.date < next })
        let animalID = animal.id
        return try context.fetch(descriptor).first { $0.animal?.id == animalID }
    }

    static func commit(records: MappedRecords, today: Date, checkIn: OralCheckIn, animal: Animal,
                       tags: [PoopTag], inputTokens: Int, outputTokens: Int, endedAt: Date,
                       context: ModelContext, calendar: Calendar = .current) throws {
        var createdIDs: [UUID] = []

        var day: FeedDay?
        if records.feedDay != nil || !records.feedings.isEmpty {
            let found = try existingFeedDay(for: animal, on: today, context: context, calendar: calendar)
            let target = found ?? FeedDay()
            if found == nil {
                target.date = today
                target.animal = animal
                context.insert(target)
                createdIDs.append(target.id)
            }
            if let mapped = records.feedDay {
                if let hours = mapped.outdoorHours { target.outdoorHours = hours }
                if let acres = mapped.outdoorAreaAcres { target.outdoorAreaAcres = acres }
                if let note = mapped.note { target.note = note }
            }
            day = target
        }

        for mapped in records.feedings {
            let feeding = Feeding()
            feeding.time = mapped.time
            feeding.note = mapped.note
            feeding.day = day
            context.insert(feeding)
            createdIDs.append(feeding.id)
            for mappedItem in mapped.items {
                let item = FeedItem()
                item.category = mappedItem.category
                item.type = mappedItem.type
                item.amount = mappedItem.amount
                item.unit = mappedItem.unit
                item.sortOrder = mappedItem.sortOrder
                item.feeding = feeding
                context.insert(item)
                createdIDs.append(item.id)
            }
        }

        if let mapped = records.poop {
            let observation = PoopObservation()
            observation.timestamp = mapped.timestamp
            observation.note = mapped.note
            observation.tags = tags.filter { mapped.tagIDs.contains($0.id) }
            observation.animal = animal
            context.insert(observation)
            createdIDs.append(observation.id)
        }

        if let mapped = records.health {
            let health = HealthCheckIn()
            health.timestamp = mapped.timestamp
            health.note = mapped.note
            health.animal = animal
            context.insert(health)
            createdIDs.append(health.id)
        }

        checkIn.status = .saved
        checkIn.errorMessage = nil
        checkIn.endedAt = endedAt
        checkIn.inputTokens = inputTokens
        checkIn.outputTokens = outputTokens
        checkIn.createdRecordIdsJSON = encodeIDs(createdIDs)
        try context.save()
    }

    /// Ends a check-in without creating records: discarded on Cancel, failed on a refusal,
    /// unparseable output, or a save that threw. The turns are kept either way.
    static func close(checkIn: OralCheckIn, status: CheckInStatus, reason: String?, endedAt: Date,
                      inputTokens: Int, outputTokens: Int, context: ModelContext) throws {
        checkIn.status = status
        checkIn.errorMessage = reason
        checkIn.endedAt = endedAt
        checkIn.inputTokens = inputTokens
        checkIn.outputTokens = outputTokens
        try context.save()
    }

    static func encodeIDs(_ ids: [UUID]) -> String {
        guard let data = try? JSONEncoder().encode(ids.map(\.uuidString)),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }
}
```

- [ ] **Step 4: Run the committer tests**

Run: `scripts/test-app.sh`
Expected: the three `CheckInCommitterTests` pass.

- [ ] **Step 5: Write the sheet**

`App/Views/CheckIn/CheckInSheetView.swift`:
```swift
import SwiftData
import SwiftUI

/// The oral check-in. Privacy notice on first use, then Talk, then Review.
struct CheckInSheetView: View {
    let animal: Animal

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @AppStorage("hasAcknowledgedCheckInPrivacy") private var hasAcknowledgedPrivacy = false
    @AppStorage("checkInQuestionCap") private var questionCap = 8
    @AppStorage("speakQuestions") private var speakQuestions = true

    @Query(sort: \PoopTag.sortOrder) private var poopTags: [PoopTag]
    @Query(sort: \AACButton.sortOrder) private var buttons: [AACButton]
    @Query(sort: \FeedItem.createdAt, order: .reverse) private var feedItems: [FeedItem]

    @State private var session: CheckInSession?
    @State private var checkIn: OralCheckIn?
    @State private var records = MappedRecords()
    @State private var speaker = QuestionSpeaker()
    @State private var transcriber = SpeechTranscriber()
    @State private var permissionDenied = false
    @State private var alertMessage: String?
    @State private var spokenQuestion: String?

    private var hasAPIKey: Bool {
        (KeychainStore().get(KeychainStore.apiKeyAccount)?.isEmpty == false)
    }

    private var activeTags: [PoopTag] { poopTags.filter { !$0.isHidden } }

    var body: some View {
        NavigationStack {
            Group {
                if !hasAcknowledgedPrivacy {
                    privacyNotice
                } else if !hasAPIKey {
                    missingKeyNotice
                } else if let session {
                    if session.state == .reviewing {
                        CheckInReviewView(session: session, records: $records, animal: animal,
                                          tags: activeTags, onSave: save, onCancel: cancel)
                    } else {
                        talkStep(session)
                    }
                } else {
                    ProgressView().onAppear(perform: begin)
                }
            }
            .navigationTitle("Check in with \(animal.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cancel() }
                }
            }
            .alert("Check-in", isPresented: Binding(get: { alertMessage != nil },
                                                    set: { if !$0 { alertMessage = nil } })) {
                Button("OK") {}
            } message: {
                Text(alertMessage ?? "")
            }
        }
    }

    // MARK: - Steps

    private var privacyNotice: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label("What gets sent", systemImage: "lock.shield")
                    .font(.headline)
                Text("When you talk to the check-in, these are sent to Anthropic over HTTPS with your own API key: what you said as text, \(animal.name)'s name and species, the sound button labels, the poop tag names, and recent feed item types and units.")
                Text("These are never sent: audio, photos, videos, voice recordings, and anything already stored in the app.")
                Text("Everything else stays on this phone.")
                    .foregroundStyle(.secondary)
                Button("I understand") { hasAcknowledgedPrivacy = true }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
            }
            .padding()
        }
    }

    private var missingKeyNotice: some View {
        ContentUnavailableView {
            Label("No API key", systemImage: "key")
        } description: {
            Text("The oral check-in sends your words to Anthropic using your own API key. Add one in Settings, under Oral check-in, then start the check-in again.")
        } actions: {
            NavigationLink("Open Settings") { SettingsView() }
        }
    }

    private func talkStep(_ session: CheckInSession) -> some View {
        VStack(spacing: 20) {
            if let question = session.currentQuestion {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Question \(session.questionCount) of \(questionCap)")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(question).font(.title3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            } else {
                Text("Tell me about \(animal.name)'s day: time outside, what you fed, poop, and anything off.")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if permissionDenied {
                Label("Microphone or speech access is off. Type your answer instead.",
                      systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            TextEditor(text: Binding(get: { session.liveTranscript },
                                     set: { session.liveTranscript = $0 }))
                .frame(minHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(.separator)))
                .accessibilityLabel("Transcript, editable")

            if session.state == .extracting {
                ProgressView("Thinking")
            } else {
                recordButton(session)
            }

            HStack {
                Button("Send") { Task { await submit(session) } }
                    .buttonStyle(.bordered)
                    .disabled(session.liveTranscript.trimmingCharacters(in: .whitespaces).isEmpty
                              || session.state == .extracting)
                Spacer()
                Button("Finish") { session.finish() }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.state == .extracting)
            }
            Spacer()
        }
        .padding()
        .onChange(of: session.currentQuestion) { _, question in
            guard speakQuestions, let question, question != spokenQuestion else { return }
            spokenQuestion = question
            speaker.speak(question)
        }
    }

    private func recordButton(_ session: CheckInSession) -> some View {
        Button {
            if session.state == .recording {
                session.stopRecording()
            } else {
                Task { await beginRecording(session) }
            }
        } label: {
            Label(session.state == .recording ? "Stop" : "Hold the thought, tap to talk",
                  systemImage: session.state == .recording ? "stop.circle.fill" : "mic.circle.fill")
                .font(.title2)
                .frame(maxWidth: .infinity, minHeight: 64)
        }
        .buttonStyle(.borderedProminent)
        .tint(session.state == .recording ? .red : ColorPalette.color(animal.colorHex))
        .disabled(permissionDenied)
        .accessibilityLabel(session.state == .recording ? "Stop recording" : "Start recording")
    }

    // MARK: - Actions

    private func begin() {
        let now = Date()
        let input = SystemPromptInput(
            animalName: animal.name,
            species: animal.species,
            tracksOutdoorTime: animal.tracksOutdoorTime,
            now: now,
            buttonLabels: buttons.filter { $0.animal?.id == animal.id && !$0.isArchived }.map(\.label),
            poopTagNames: activeTags.map(\.name),
            recentFeedTypes: recentValues(feedItems.map(\.type), limit: SystemPromptBuilder.maxFeedTypes),
            recentFeedUnits: recentValues(feedItems.map(\.unit), limit: SystemPromptBuilder.maxFeedUnits))

        let made = CheckInSession(
            client: LiveClaudeClient(),
            transcriber: transcriber,
            system: SystemPromptBuilder.build(input),
            schema: CheckInSchema.dictionary,
            questionCap: questionCap,
            apiKeyProvider: { KeychainStore().get(KeychainStore.apiKeyAccount) })
        session = made
        checkIn = CheckInCommitter.start(animal: animal, startedAt: made.startedAt, context: context)
    }

    /// Distinct, most recent first, case-insensitive, keeping the most recent spelling.
    private func recentValues(_ values: [String], limit: Int) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            out.append(trimmed)
            if out.count == limit { break }
        }
        return out
    }

    private func beginRecording(_ session: CheckInSession) async {
        guard await transcriber.requestAuthorization() else {
            permissionDenied = true
            alertMessage = TranscriberError.notAuthorized.errorDescription
            return
        }
        do {
            try session.startRecording()
        } catch {
            permissionDenied = true
            alertMessage = (error as? TranscriberError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func submit(_ session: CheckInSession) async {
        await session.submit()
        persistTurns(session)
        if session.state == .reviewing { prepareReview(session) }
    }

    private func persistTurns(_ session: CheckInSession) {
        guard let checkIn else { return }
        CheckInCommitter.syncTurns(session.turns, to: checkIn, context: context)
        try? context.save()
    }

    private func prepareReview(_ session: CheckInSession) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: session.startedAt)
        let existing = try? CheckInCommitter.existingFeedDay(for: animal, on: today, context: context)
        records = DraftMapper.map(
            draft: session.draft,
            animal: AnimalSnapshot(animal),
            today: today,
            existingDay: existing.map {
                ExistingFeedDaySnapshot(outdoorHours: $0.outdoorHours,
                                        outdoorAreaAcres: $0.outdoorAreaAcres, note: $0.note)
            },
            tags: activeTags.map { CheckInTagOption(id: $0.id, name: $0.name) },
            now: session.startedAt,
            calendar: calendar)

        if let reason = session.failureReason, let checkIn {
            try? CheckInCommitter.close(checkIn: checkIn, status: .failed, reason: reason,
                                        endedAt: Date(), inputTokens: session.inputTokens,
                                        outputTokens: session.outputTokens, context: context)
        }
    }

    private func save() {
        guard let session, let checkIn else { return }
        speaker.stop()
        persistTurns(session)
        do {
            try CheckInCommitter.commit(records: records,
                                        today: Calendar.current.startOfDay(for: session.startedAt),
                                        checkIn: checkIn, animal: animal, tags: activeTags,
                                        inputTokens: session.inputTokens,
                                        outputTokens: session.outputTokens,
                                        endedAt: Date(), context: context)
            session.markSaved()
            dismiss()
        } catch {
            session.markFailed(error.localizedDescription)
            alertMessage = "Could not save the check-in: \(error.localizedDescription). Nothing was written."
        }
    }

    private func cancel() {
        speaker.stop()
        if let session {
            session.stopRecording()
            persistTurns(session)
            session.markDiscarded()
            if let checkIn, checkIn.status == .inProgress {
                try? CheckInCommitter.close(checkIn: checkIn, status: .discarded, reason: nil,
                                            endedAt: Date(), inputTokens: session.inputTokens,
                                            outputTokens: session.outputTokens, context: context)
            }
        }
        dismiss()
    }
}
```

- [ ] **Step 6: Write the review step**

`App/Views/CheckIn/CheckInReviewView.swift`:
```swift
import SwiftUI

/// The last step: everything the draft mapped to, editable, then Save or Cancel.
struct CheckInReviewView: View {
    let session: CheckInSession
    @Binding var records: MappedRecords
    let animal: Animal
    let tags: [PoopTag]
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        Form {
            if let reason = session.failureReason {
                Section {
                    Label(reason, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text("Your words were kept below. Fill in whatever is right and save, or cancel.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

            if !records.warnings.isEmpty {
                Section("Check these") {
                    ForEach(records.warnings, id: \.self) { warning in
                        Text(warning).font(.footnote)
                    }
                }
            }

            if records.feedDay != nil {
                Section("Feed day") {
                    if animal.tracksOutdoorTime {
                        numberRow("Outdoor hours", value: Binding(
                            get: { records.feedDay?.outdoorHours },
                            set: { records.feedDay?.outdoorHours = $0 }))
                        numberRow("Outdoor acres", value: Binding(
                            get: { records.feedDay?.outdoorAreaAcres },
                            set: { records.feedDay?.outdoorAreaAcres = $0 }))
                    }
                    TextField("Note", text: Binding(
                        get: { records.feedDay?.note ?? "" },
                        set: { records.feedDay?.note = $0.isEmpty ? nil : $0 }), axis: .vertical)
                }
            }

            ForEach(Array(records.feedings.indices), id: \.self) { index in
                Section("Feeding \(index + 1)") {
                    DatePicker("Time", selection: $records.feedings[index].time,
                               displayedComponents: [.hourAndMinute])
                    ForEach(Array(records.feedings[index].items.indices), id: \.self) { itemIndex in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(records.feedings[index].items[itemIndex].category.rawValue.capitalized)
                                .font(.caption).foregroundStyle(.secondary)
                            TextField("Type", text: $records.feedings[index].items[itemIndex].type)
                            HStack {
                                TextField("Amount", value: $records.feedings[index].items[itemIndex].amount,
                                          format: .number)
                                    .keyboardType(.decimalPad)
                                TextField("Unit", text: $records.feedings[index].items[itemIndex].unit)
                            }
                        }
                    }
                    .onDelete { offsets in records.feedings[index].items.remove(atOffsets: offsets) }
                    TextField("Feeding note", text: Binding(
                        get: { records.feedings[index].note ?? "" },
                        set: { records.feedings[index].note = $0.isEmpty ? nil : $0 }), axis: .vertical)
                }
            }
            .onDelete { offsets in records.feedings.remove(atOffsets: offsets) }

            if let poop = records.poop {
                Section("Poop") {
                    Text(poop.tagNames.joined(separator: ", "))
                    TextField("Note", text: Binding(
                        get: { records.poop?.note ?? "" },
                        set: { records.poop?.note = $0.isEmpty ? nil : $0 }), axis: .vertical)
                    Button("Do not save this observation", role: .destructive) { records.poop = nil }
                }
            }

            if records.health != nil {
                Section("Health check-in") {
                    TextField("Note", text: Binding(
                        get: { records.health?.note ?? "" },
                        set: { records.health?.note = $0 }), axis: .vertical)
                    Button("Do not save this check-in", role: .destructive) { records.health = nil }
                }
            }

            Section("Transcript") {
                ForEach(session.turns.filter { $0.role == .user }) { turn in
                    Text(turn.text).font(.footnote)
                }
            }

            Section("Usage") {
                LabeledContent("Input tokens", value: "\(session.inputTokens)")
                LabeledContent("Output tokens", value: "\(session.outputTokens)")
                LabeledContent("Questions asked", value: "\(session.questionCount)")
            }

            Section {
                Button("Save") { onSave() }
                    .disabled(records.isEmpty)
                Button("Cancel", role: .destructive) { onCancel() }
            } footer: {
                Text(records.isEmpty
                     ? "There is nothing to save. Cancel keeps the transcript on this check-in."
                     : "Save writes every record above in one go.")
            }
        }
    }

    private func numberRow(_ title: String, value: Binding<Double?>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("none", value: value, format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 100)
        }
    }
}
```

- [ ] **Step 7: Replace the placeholder entry point**

In `App/AnimalSwitcher.swift`, replace the whole placeholder, which currently reads:
```swift
/// Placeholder until Plan F supplies the real sheet.
struct OralCheckInEntry: View {
    var body: some View {
        ContentUnavailableView("Oral check-in", systemImage: "mic.circle",
                               description: Text("Talk-to-log arrives in a later update."))
    }
}
```
with:
```swift
/// The mic toolbar button's destination: the real oral check-in for the selected animal.
struct OralCheckInEntry: View {
    @Environment(\.selectedAnimal) private var selectedAnimal

    var body: some View {
        if let selectedAnimal {
            CheckInSheetView(animal: selectedAnimal)
        } else {
            ContentUnavailableView("No animal selected", systemImage: "pawprint",
                                   description: Text("Pick an animal from the menu before starting a check-in."))
        }
    }
}
```

- [ ] **Step 8: Run the tests and look at the app**

Run: `scripts/test-app.sh`
Expected: all three `CheckInCommitterTests` pass and every earlier test still passes.

Run: `scripts/run-sim.sh`, then in the simulator add a horse, tap the microphone icon in the navigation bar, and read `build/screenshot.png`. Expected on first use: the privacy notice listing what is and is not sent. Tap "I understand" with no API key saved and confirm the missing-key screen with the Open Settings link. Save any non-empty key in Settings, reopen the check-in, type "She was out six hours and had two flakes of hay" into the transcript field and tap Finish to reach Review without a network call. With a real key on the phone, run one full voice check-in.

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "feat(checkin): commit records in one transaction, the oral check-in sheet with review, and the real mic entry point

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Self-Review

Run after the plan is written, before execution starts. Results recorded here.

**Spec coverage.** Every requirement in the spec's oral check-in sections maps to a task. Data model: Task 1. Settings keys: Global Constraints plus Task 10's `hasAcknowledgedCheckInPrivacy`. Sheet flow steps 1 to 4: Tasks 8, 9, 10. Required fields and question order: Task 2 (`CheckInField`) and Task 6. `CheckInDraft` shape: Task 2. Mapping rules: Task 7. Claude request headers and body: Task 4. Response handling by stop reason: Tasks 3 and 9. URLSession, timeout, one retry, no streaming: Task 5. `ClaudeClient` protocol with a live implementation and a scripted double: Task 5. `CheckInSession` as an `@Observable` machine depending only on `ClaudeClient` and `Transcriber`: Task 9. `DraftMapper` with warnings: Task 7. Request builder and response parser tested against recorded fixtures: Tasks 3 and 4. Error-handling list (missing key, denied permission, no network, 401, 429, 5xx, refusal, unparseable, transcript never lost, Review always reachable): `ClaudeClientError` copy in Task 5, session paths in Task 9, sheet alerts and the permission fallback in Task 10. Registration points from the model contract (`PersistenceController.modelTypes`, `AnimalDeletionPolicy.recordCounts`): Task 1. The one contract registration point this plan does not touch is `Seeds.all`, because the check-in seeds nothing, and there is no `SettingsPlaceholderRow` to replace because Plan A already shipped the check-in settings; both are recorded in Assumptions.

**Placeholder scan.** No "TBD", "similar to Task N", "add validation" or "handle errors appropriately" appears. Every code step carries the full file or the exact replacement text, including the two registration edits in Task 1 and the `OralCheckInEntry` replacement in Task 10, which quotes the text being replaced so it can be found without reading another plan.

**Type consistency.** Checked across tasks: `ClaudeMessage.user` / `.assistant` (Task 4) are what `CheckInSession.apiMessages()` builds and what the Task 5 and Task 9 tests assert. `ClaudeResponse(stopReason:jsonText:inputTokens:outputTokens:model:refusalCategory:refusalExplanation:)` (Task 3) is the initializer Tasks 5 and 9 call. `CheckInSchema.dictionary` (Task 2) is the argument name `schema:` in Tasks 4, 5, 9 and 10. `CheckInDraft.decode` / `.empty` (Task 2) are used unchanged in Tasks 3 and 9. `CheckInField.allCases.map(\.rawValue)` is the same list in the schema's `missing` enum (Task 2) and the prompt's field order (Task 6). `DraftMapper.map(draft:animal:today:existingDay:tags:now:calendar:)` (Task 7) is called with exactly those labels in Task 10. `MappedRecords` fields are all `var` so Task 10's Review can bind to them. `CheckInSession.SessionTurn` (Task 9) is the element type `CheckInCommitter.syncTurns` takes (Task 10). `CheckInCommitter.existingFeedDay(for:on:context:calendar:)` is used by both the commit path and the review preparation with the same labels. `ClaudeRequestBuilder.model` is the single source of the model string for both the request body and `OralCheckIn.model`. `TranscriberError` is `Equatable` because the Task 8 test compares cases.
