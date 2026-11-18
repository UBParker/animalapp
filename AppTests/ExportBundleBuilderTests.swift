import AnimalVoiceAudio
import SwiftData
import XCTest
@testable import AnimalTracker

@MainActor
final class ExportBundleBuilderTests: XCTestCase {
    private struct Fixture {
        let context: ModelContext
        let juniper: Animal
        let withAnimal: VoiceRecording
        let without: VoiceRecording
    }

    private func fixture() throws -> Fixture {
        let context = try TestSupport.container().mainContext
        let juniper = Animal(name: "Juniper", species: "horse")
        juniper.isArchived = true
        context.insert(juniper)
        context.insert(VoiceTag(kind: .meaning, name: "Wants out"))
        let withAnimal = VoiceRecording(audioFilename: "a-audio.m4a", durationS: 2, animal: juniper)
        withAnimal.createdAt = Date(timeIntervalSince1970: 1_000)
        context.insert(withAnimal)
        let vocalization = Vocalization(segment: Segment(startS: 0.1, endS: 0.5), features: VoiceFixtures.features())
        vocalization.recording = withAnimal
        context.insert(vocalization)
        let without = VoiceRecording(audioFilename: "b-audio.m4a", durationS: 1)
        without.createdAt = Date(timeIntervalSince1970: 2_000)
        context.insert(without)
        try context.save()
        return Fixture(context: context, juniper: juniper, withAnimal: withAnimal, without: without)
    }

    func testRelationshipsAreIds() throws {
        let f = try fixture()
        let bundle = try ExportBundleBuilder.build(context: f.context)
        XCTAssertEqual(bundle.voiceRecordings.count, 2)
        XCTAssertEqual(bundle.vocalizations.count, 1)
        XCTAssertEqual(bundle.vocalizations[0].recordingId, f.withAnimal.id.uuidString)
        XCTAssertEqual(bundle.voiceRecordings[0].id, f.withAnimal.id.uuidString)
        XCTAssertEqual(bundle.voiceRecordings[0].animalId, f.juniper.id.uuidString)
        XCTAssertEqual(bundle.voiceRecordings[1].id, f.without.id.uuidString)
        XCTAssertNil(bundle.voiceRecordings[1].animalId)
        XCTAssertTrue(bundle.voiceTags.contains { $0.name == "Wants out" && $0.kind == "meaning" && !$0.isBuiltIn })
    }

    func testArchivedAnimalIsExported() throws {
        let f = try fixture()
        let bundle = try ExportBundleBuilder.build(context: f.context)
        XCTAssertEqual(bundle.animals.count, 1)
        XCTAssertEqual(bundle.animals[0].name, "Juniper")
        XCTAssertTrue(bundle.animals[0].isArchived)
    }

    func testOrderIsCreatedAtThenId() throws {
        let context = try TestSupport.container().mainContext
        let same = Date(timeIntervalSince1970: 5_000)
        let high = VoiceRecording(audioFilename: "h-audio.m4a", durationS: 1)
        high.id = UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000000")!
        high.createdAt = same
        let low = VoiceRecording(audioFilename: "l-audio.m4a", durationS: 1)
        low.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        low.createdAt = same
        context.insert(high)
        context.insert(low)
        try context.save()
        let bundle = try ExportBundleBuilder.build(context: context)
        XCTAssertEqual(bundle.voiceRecordings.map(\.id), [low.id.uuidString, high.id.uuidString])
    }

    func testEmptyStoreProducesAllKeys() throws {
        let context = try TestSupport.container().mainContext
        let data = try JSONExporter.data(try ExportBundleBuilder.build(context: context))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let expected: Set<String> = [
            "version", "animals", "buttons", "presses", "feedDays", "feedings", "feedItems", "poopTags",
            "poopObservations", "healthCheckIns", "oralCheckIns", "checkInTurns", "voiceTags",
            "voiceRecordings", "vocalizations",
        ]
        XCTAssertEqual(Set(object.keys), expected)
        XCTAssertEqual(object["version"] as? Int, 4)
        for key in expected.subtracting(["version", "voiceTags"]) {
            XCTAssertEqual((object[key] as? [Any])?.count, 0, key)
        }
        XCTAssertNotNil(object["voiceTags"] as? [Any])
    }
}
