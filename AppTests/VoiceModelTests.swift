import AnimalVoiceAudio
import SwiftData
import XCTest
@testable import AnimalTracker

enum VoiceFixtures {
    static func features(duration: Double = 0.4, f0: Double? = 600, slope: Double? = 100) -> VocalFeatures {
        VocalFeatures(durationS: duration, f0Mean: f0, f0Min: f0.map { $0 - 50 }, f0Max: f0.map { $0 + 50 }, f0Slope: slope,
                      voicedFraction: f0 == nil ? 0 : 0.9, rmsDb: -20, spectralCentroidHz: 1500, mfcc: Array(repeating: 0, count: 13))
    }
}

@MainActor
final class VoiceModelTests: XCTestCase {
    func testRoundTripWithRelationships() throws {
        let context = try TestSupport.container().mainContext
        let animal = Animal(name: "Miso", species: "cat")
        context.insert(animal)
        let recording = VoiceRecording(audioFilename: "abc-audio.m4a", durationS: 1.5, animal: animal)
        context.insert(recording)
        let v = Vocalization(segment: Segment(startS: 0.1, endS: 0.5), features: VoiceFixtures.features())
        v.recording = recording
        context.insert(v)
        try context.save()

        let recordings = try context.fetch(FetchDescriptor<VoiceRecording>())
        XCTAssertEqual(recordings.count, 1)
        XCTAssertEqual(recordings[0].animal?.name, "Miso")
        XCTAssertEqual(recordings[0].sortedVocalizations.count, 1)
        XCTAssertEqual(v.durationS, 0.4, accuracy: 1e-9)
        XCTAssertEqual(v.features.mfcc.count, 13)
        XCTAssertEqual(v.featureVector.count, 21)
        XCTAssertEqual(v.featureVector[1], 600)
        XCTAssertEqual(recording.status, .recorded)
        recording.status = .analyzed
        XCTAssertEqual(recording.statusRaw, "analyzed")
        XCTAssertEqual(try AnimalDeletionPolicy.recordCounts(for: animal, context: context)["voice recordings"], 1)
        XCTAssertFalse(try AnimalDeletionPolicy.canDelete(animal, context: context))
    }

    func testDeletingRecordingCascadesVocalizations() throws {
        let context = try TestSupport.container().mainContext
        let recording = VoiceRecording(audioFilename: "x-audio.m4a", durationS: 1)
        context.insert(recording)
        let v = Vocalization(segment: Segment(startS: 0, endS: 0.2), features: VoiceFixtures.features())
        v.recording = recording
        context.insert(v)
        try context.save()
        context.delete(recording)
        try context.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<Vocalization>()).count, 0)
    }
}
