import AnimalVoiceAudio
import AnimalVoiceStats
import SwiftData
import XCTest
@testable import AnimalTracker

@MainActor
final class PredictionServiceTests: XCTestCase {
    private func makeAnimal(context: ModelContext, hungry: Int, annoyed: Int, species: String = "cat") throws -> Animal {
        let animal = Animal(name: "Miso", species: species)
        context.insert(animal)
        let recording = VoiceRecording(audioFilename: "r-audio.m4a", durationS: 30, animal: animal)
        context.insert(recording)
        var t = 0.0
        for i in 0..<hungry {
            let v = Vocalization(segment: Segment(startS: t, endS: t + 0.3), features: VoiceFixtures.features(duration: 0.3, f0: 800 + Double(i) * 10, slope: 200))
            v.meaningTag = "Hungry"; v.recording = recording; context.insert(v); t += 1
        }
        for i in 0..<annoyed {
            let v = Vocalization(segment: Segment(startS: t, endS: t + 1.2), features: VoiceFixtures.features(duration: 1.2, f0: 400 + Double(i) * 10, slope: -100))
            v.meaningTag = "Annoyed"; v.recording = recording; context.insert(v); t += 2
        }
        let unknown = Vocalization(segment: Segment(startS: t, endS: t + 0.5), features: VoiceFixtures.features())
        unknown.meaningTag = VoiceTagSeed.unknownMeaning; unknown.recording = recording; context.insert(unknown)
        let untagged = Vocalization(segment: Segment(startS: t + 1, endS: t + 1.5), features: VoiceFixtures.features())
        untagged.recording = recording; context.insert(untagged)
        try context.save()
        return animal
    }

    func testReadyAnimalPredictsNearestMeaning() throws {
        let context = try TestSupport.container().mainContext
        let animal = try makeAnimal(context: context, hungry: 6, annoyed: 6)
        XCTAssertEqual(try PredictionService.labeledSamples(for: animal, context: context).count, 12, "Unknown and untagged sounds are excluded")

        let result = try PredictionService.predict(features: VoiceFixtures.features(duration: 0.35, f0: 780, slope: 150), for: animal, context: context)
        guard case .ready = result.readiness else { return XCTFail("expected ready, got \(result.readiness)") }
        XCTAssertEqual(result.prediction?.best?.label, "Hungry")
        XCTAssertGreaterThan(result.prediction?.best?.probability ?? 0, 0.8)
        XCTAssertEqual(result.neighbors.count, 5)
        XCTAssertTrue(result.neighbors.allSatisfy { $0.meaningTag == "Hungry" })
        XCTAssertGreaterThan(result.evaluation?.accuracy ?? 0, 0.9)
        XCTAssertNotNil(result.researchHint, "cats get the Meowsic hint")
    }

    func testDogGetsNoResearchHint() throws {
        let context = try TestSupport.container().mainContext
        let animal = try makeAnimal(context: context, hungry: 6, annoyed: 6, species: "dog")
        let result = try PredictionService.predict(features: VoiceFixtures.features(duration: 0.35, f0: 780, slope: 150), for: animal, context: context)
        XCTAssertEqual(result.prediction?.best?.label, "Hungry")
        XCTAssertNil(result.researchHint)
    }

    func testNotReadyAnimal() throws {
        let context = try TestSupport.container().mainContext
        let animal = try makeAnimal(context: context, hungry: 5, annoyed: 3)
        let result = try PredictionService.predict(features: VoiceFixtures.features(), for: animal, context: context)
        guard case let .notReady(_, needed) = result.readiness else { return XCTFail("expected notReady") }
        XCTAssertEqual(needed, ["Annoyed": 2])
        XCTAssertNil(result.prediction)
        XCTAssertTrue(result.neighbors.isEmpty)
    }

    func testOtherAnimalsDataIsNotUsed() throws {
        let context = try TestSupport.container().mainContext
        _ = try makeAnimal(context: context, hungry: 6, annoyed: 6)
        let empty = Animal(name: "Rex", species: "dog")
        context.insert(empty)
        try context.save()
        XCTAssertEqual(try PredictionService.labeledSamples(for: empty, context: context).count, 0)
    }
}
