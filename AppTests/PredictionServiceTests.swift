import AnimalVoiceAudio
import AnimalVoiceStats
import SwiftData
import XCTest
@testable import AnimalTracker

@MainActor
final class PredictionServiceTests: XCTestCase {
    private func makeAnimal(context: ModelContext, hungry: Int, annoyed: Int, species: String = "cat",
                            name: String = "Miso", hungryLabel: String = "Hungry",
                            annoyedLabel: String = "Annoyed") throws -> Animal {
        let animal = Animal(name: name, species: species)
        context.insert(animal)
        let recording = VoiceRecording(audioFilename: "r-audio.m4a", durationS: 30, animal: animal)
        context.insert(recording)
        var t = 0.0
        for i in 0..<hungry {
            let v = Vocalization(segment: Segment(startS: t, endS: t + 0.3), features: VoiceFixtures.features(duration: 0.3, f0: 800 + Double(i) * 10, slope: 200))
            v.meaningTag = hungryLabel; v.recording = recording; context.insert(v); t += 1
        }
        for i in 0..<annoyed {
            let v = Vocalization(segment: Segment(startS: t, endS: t + 1.2), features: VoiceFixtures.features(duration: 1.2, f0: 400 + Double(i) * 10, slope: -100))
            v.meaningTag = annoyedLabel; v.recording = recording; context.insert(v); t += 2
        }
        let unknown = Vocalization(segment: Segment(startS: t, endS: t + 0.5), features: VoiceFixtures.features())
        unknown.meaningTag = VoiceTagSeed.unknownMeaning; unknown.recording = recording; context.insert(unknown)
        let untagged = Vocalization(segment: Segment(startS: t + 1, endS: t + 1.5), features: VoiceFixtures.features())
        untagged.recording = recording; context.insert(untagged)
        try context.save()
        return animal
    }

    func testReadyAnimalPredictsNearestMeaning() async throws {
        let context = try TestSupport.container().mainContext
        let animal = try makeAnimal(context: context, hungry: 6, annoyed: 6)
        XCTAssertEqual(try PredictionService.labeledSamples(for: animal, context: context).count, 12, "Unknown and untagged sounds are excluded")

        let result = try await PredictionService.predict(features: VoiceFixtures.features(duration: 0.35, f0: 780, slope: 150), for: animal, context: context)
        guard case .ready = result.readiness else { return XCTFail("expected ready, got \(result.readiness)") }
        XCTAssertEqual(result.prediction?.best?.label, "Hungry")
        XCTAssertGreaterThan(result.prediction?.best?.probability ?? 0, 0.8)
        XCTAssertEqual(result.neighbors.count, 5)
        XCTAssertTrue(result.neighbors.allSatisfy { $0.meaningTag == "Hungry" })
        XCTAssertGreaterThan(result.evaluation?.accuracy ?? 0, 0.9)
        XCTAssertNotNil(result.researchHint, "cats get the Meowsic hint")
    }

    func testDogGetsNoResearchHint() async throws {
        let context = try TestSupport.container().mainContext
        let animal = try makeAnimal(context: context, hungry: 6, annoyed: 6, species: "dog")
        let result = try await PredictionService.predict(features: VoiceFixtures.features(duration: 0.35, f0: 780, slope: 150), for: animal, context: context)
        XCTAssertEqual(result.prediction?.best?.label, "Hungry")
        XCTAssertNil(result.researchHint)
    }

    func testNotReadyAnimal() async throws {
        let context = try TestSupport.container().mainContext
        let animal = try makeAnimal(context: context, hungry: 5, annoyed: 3)
        let result = try await PredictionService.predict(features: VoiceFixtures.features(), for: animal, context: context)
        guard case let .notReady(_, needed) = result.readiness else { return XCTFail("expected notReady") }
        XCTAssertEqual(needed, ["Annoyed": 2])
        XCTAssertNil(result.prediction)
        XCTAssertTrue(result.neighbors.isEmpty)
    }

    /// Two animals with full, disjoint label sets in one store: neither one's sounds may reach the other's model.
    func testOtherAnimalsDataIsNotUsed() async throws {
        let context = try TestSupport.container().mainContext
        let miso = try makeAnimal(context: context, hungry: 6, annoyed: 6)
        let rex = try makeAnimal(context: context, hungry: 6, annoyed: 6, species: "dog", name: "Rex",
                                 hungryLabel: "Playful", annoyedLabel: "Scared")
        let empty = Animal(name: "Ghost", species: "goat")
        context.insert(empty)
        try context.save()
        XCTAssertEqual(try PredictionService.labeledSamples(for: empty, context: context).count, 0)
        XCTAssertEqual(try PredictionService.labeledSamples(for: miso, context: context).count, 12)
        XCTAssertEqual(try PredictionService.labeledSamples(for: rex, context: context).count, 12)

        let query = VoiceFixtures.features(duration: 0.35, f0: 780, slope: 150)
        let forMiso = try await PredictionService.predict(features: query, for: miso, context: context)
        XCTAssertEqual(forMiso.evaluation?.n, 12, "Trained on Miso's 12 labeled sounds, not all 24 in the store")
        XCTAssertEqual(Set(try XCTUnwrap(forMiso.prediction).probabilities.keys), ["Hungry", "Annoyed"])
        XCTAssertTrue(forMiso.neighbors.allSatisfy { $0.recording?.animal?.id == miso.id })

        let forRex = try await PredictionService.predict(features: query, for: rex, context: context)
        XCTAssertEqual(forRex.evaluation?.n, 12)
        XCTAssertEqual(Set(try XCTUnwrap(forRex.prediction).probabilities.keys), ["Playful", "Scared"])
        XCTAssertTrue(forRex.neighbors.allSatisfy { $0.recording?.animal?.id == rex.id })
    }
}
