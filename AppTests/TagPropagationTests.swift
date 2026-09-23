import AnimalVoiceAudio
import SwiftData
import XCTest
@testable import AnimalTracker

@MainActor
final class TagPropagationTests: XCTestCase {
    func testAppliesToNonOverriddenOnlyAndResets() throws {
        let context = try TestSupport.container().mainContext
        let recording = VoiceRecording(audioFilename: "r-audio.m4a", durationS: 2)
        context.insert(recording)
        let a = Vocalization(segment: Segment(startS: 0, endS: 0.3), features: VoiceFixtures.features())
        let b = Vocalization(segment: Segment(startS: 1, endS: 1.3), features: VoiceFixtures.features())
        a.recording = recording
        b.recording = recording
        b.overridden = true
        b.meaningTag = "Annoyed"
        context.insert(a)
        context.insert(b)
        recording.activityTag = "Eating"
        recording.meaningTag = "Hungry"
        recording.userConfidence = 3

        TagPropagation.apply(to: recording)
        XCTAssertEqual(a.activityTag, "Eating")
        XCTAssertEqual(a.meaningTag, "Hungry")
        XCTAssertEqual(a.userConfidence, 3)
        XCTAssertEqual(b.meaningTag, "Annoyed")
        XCTAssertNil(b.activityTag)
        XCTAssertFalse(TagPropagation.differsFromRecording(a))
        XCTAssertTrue(TagPropagation.differsFromRecording(b))

        TagPropagation.resetOverride(b)
        XCTAssertFalse(b.overridden)
        XCTAssertEqual(b.meaningTag, "Hungry")
        XCTAssertEqual(b.activityTag, "Eating")
    }
}
