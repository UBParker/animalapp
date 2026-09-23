import AnimalVoiceAudio
import SwiftData
import XCTest
@testable import AnimalTracker

@MainActor
final class AnalysisServiceTests: XCTestCase {
    func testAnalyzeCreatesVocalizationsAndPropagatesTags() async throws {
        let context = try TestSupport.container().mainContext
        let store = InMemoryMediaStore()
        let filename = try store.saveAudio(from: TestAudioFile.toneBurstM4A())
        let recording = VoiceRecording(audioFilename: filename, durationS: 1.0)
        recording.meaningTag = "Hungry"
        context.insert(recording)

        await AnalysisService.analyze(recording: recording, mediaStore: store, context: context)

        XCTAssertEqual(recording.status, .analyzed, recording.errorMessage ?? "")
        XCTAssertEqual(recording.vocalizations?.count, 1)
        let v = try XCTUnwrap(recording.sortedVocalizations.first)
        XCTAssertEqual(v.startS, 0.3, accuracy: 0.1)
        XCTAssertEqual(v.durationS, 0.4, accuracy: 0.1)
        XCTAssertEqual(v.f0Mean ?? 0, 600, accuracy: 18)
        XCTAssertEqual(v.meaningTag, "Hungry")
        XCTAssertEqual(recording.durationS, 1.0, accuracy: 0.1)
    }

    func testNothingAboveFloorIsNoSounds() async throws {
        let context = try TestSupport.container().mainContext
        let store = InMemoryMediaStore()
        var config = SegmenterConfig()
        config.absoluteFloorDbfs = 10 // nothing can pass the floor
        let recording = VoiceRecording(audioFilename: try store.saveAudio(from: TestAudioFile.toneBurstM4A()), durationS: 1.0)
        context.insert(recording)
        await AnalysisService.analyze(recording: recording, mediaStore: store, context: context, segmenter: config)
        XCTAssertEqual(recording.status, .noSounds)
        XCTAssertEqual(recording.vocalizations?.count ?? 0, 0)
    }

    func testMissingAudioFails() async throws {
        let context = try TestSupport.container().mainContext
        let recording = VoiceRecording(audioFilename: "missing-audio.m4a", durationS: 0)
        context.insert(recording)
        await AnalysisService.analyze(recording: recording, mediaStore: InMemoryMediaStore(), context: context)
        XCTAssertEqual(recording.status, .failed)
        XCTAssertNotNil(recording.errorMessage)
    }

    func testReanalyzeReplacesVocalizationsAndRepropagatesTags() async throws {
        let context = try TestSupport.container().mainContext
        let store = InMemoryMediaStore()
        let recording = VoiceRecording(audioFilename: try store.saveAudio(from: TestAudioFile.toneBurstM4A()), durationS: 1.0)
        context.insert(recording)
        await AnalysisService.analyze(recording: recording, mediaStore: store, context: context)
        XCTAssertEqual(recording.vocalizations?.count, 1)

        recording.meaningTag = "Annoyed"
        let first = try XCTUnwrap(recording.sortedVocalizations.first)
        first.overridden = true
        first.meaningTag = "Custom"

        var config = SegmenterConfig()
        config.relativeThresholdDb = 40
        await AnalysisService.analyze(recording: recording, mediaStore: store, context: context, segmenter: config)

        XCTAssertEqual(recording.status, .analyzed, recording.errorMessage ?? "")
        XCTAssertEqual(recording.vocalizations?.count, 1)
        XCTAssertEqual(recording.sortedVocalizations.first?.meaningTag, "Annoyed")
        XCTAssertEqual(try context.fetch(FetchDescriptor<Vocalization>()).count, 1)
    }

    /// The user can delete a recording while its analysis runs. The deleted model has no context,
    /// and applying a result to it would insert sounds hanging off a row the store already dropped.
    func testApplyToADeletedRecordingIsANoOp() throws {
        let context = try TestSupport.container().mainContext
        let recording = VoiceRecording(audioFilename: "doomed-audio.m4a", durationS: 1.0)
        context.insert(recording)
        try context.save()
        context.delete(recording)
        try context.save()

        let result = AnalysisService.Result(durationS: 2.0,
                                            events: [(segment: Segment(startS: 0, endS: 0.4), features: VoiceFixtures.features())])
        XCTAssertNoThrow(try AnalysisService.apply(result, to: recording, context: context))

        XCTAssertEqual(try context.fetch(FetchDescriptor<VoiceRecording>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Vocalization>()).count, 0)
        XCTAssertEqual(recording.status, .recorded, "no status is written onto a deleted recording")
        XCTAssertEqual(recording.durationS, 1.0, "no duration is written onto a deleted recording")
        XCTAssertFalse(context.hasChanges, "nothing is left pending on the context")
    }
}
