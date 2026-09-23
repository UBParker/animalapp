import AnimalVoiceAudio
import SwiftData
import XCTest
@testable import AnimalTracker

@MainActor
final class RecordingDeleterTests: XCTestCase {
    func testDeleteRemovesTheRowAndTheAudioFile() throws {
        let context = try TestSupport.container().mainContext
        let store = InMemoryMediaStore()
        let filename = try store.saveAudio(from: TestAudioFile.toneBurstM4A())
        let recording = VoiceRecording(audioFilename: filename, durationS: 1)
        context.insert(recording)
        try context.save()
        XCTAssertTrue(store.exists(filename))

        try RecordingDeleter.delete(recording, context: context, mediaStore: store)

        XCTAssertEqual(try context.fetch(FetchDescriptor<VoiceRecording>()).count, 0)
        XCTAssertFalse(store.exists(filename), "the audio file goes once the row's delete is saved")
    }

    /// The sounds go with the recording, and the one file the recording owns goes with them.
    func testDeleteTakesTheRecordingsSoundsWithIt() throws {
        let context = try TestSupport.container().mainContext
        let store = InMemoryMediaStore()
        let filename = try store.saveAudio(from: TestAudioFile.toneBurstM4A())
        let recording = VoiceRecording(audioFilename: filename, durationS: 1)
        context.insert(recording)
        let v = Vocalization(segment: Segment(startS: 0, endS: 0.4), features: VoiceFixtures.features())
        v.recording = recording
        context.insert(v)
        try context.save()

        try RecordingDeleter.delete(recording, context: context, mediaStore: store)

        XCTAssertEqual(try context.fetch(FetchDescriptor<Vocalization>()).count, 0)
        XCTAssertFalse(store.exists(filename))
    }
}
