import AnimalVoiceAudio
import SwiftData
import XCTest
@testable import AnimalTracker

@MainActor
final class VoiceTagRenameTests: XCTestCase {
    private func makeStore() throws -> (ModelContext, VoiceRecording, Vocalization) {
        let context = try TestSupport.container().mainContext
        let recording = VoiceRecording(audioFilename: "r-audio.m4a", durationS: 1)
        recording.activityTag = "Eating"
        recording.meaningTag = "Hungry"
        context.insert(recording)
        let v = Vocalization(segment: Segment(startS: 0, endS: 0.4), features: VoiceFixtures.features())
        v.activityTag = "Eating"
        v.meaningTag = "Hungry"
        v.recording = recording
        context.insert(v)
        try context.save()
        return (context, recording, v)
    }

    func testRenamingAMeaningMigratesExistingLabels() throws {
        let (context, recording, v) = try makeStore()
        let tag = VoiceTag(kind: .meaning, name: "Hungry", isBuiltIn: true)
        context.insert(tag)
        try context.save()

        try VoiceTagRenamer.rename(tag: tag, to: "Wants food", context: context)

        XCTAssertEqual(tag.name, "Wants food")
        XCTAssertEqual(recording.meaningTag, "Wants food")
        XCTAssertEqual(v.meaningTag, "Wants food")
        XCTAssertEqual(recording.activityTag, "Eating", "the activity label is a different kind")
        XCTAssertEqual(v.activityTag, "Eating")
        XCTAssertFalse(context.hasChanges, "the rename and the migration land in one save")
    }

    func testRenamingAnActivityMigratesOnlyActivityLabels() throws {
        let (context, recording, v) = try makeStore()
        let tag = VoiceTag(kind: .activity, name: "Eating", isBuiltIn: true)
        context.insert(tag)
        try context.save()

        try VoiceTagRenamer.rename(tag: tag, to: "At the bowl", context: context)

        XCTAssertEqual(recording.activityTag, "At the bowl")
        XCTAssertEqual(v.activityTag, "At the bowl")
        XCTAssertEqual(recording.meaningTag, "Hungry", "the meaning label keeps its own name")
        XCTAssertEqual(v.meaningTag, "Hungry")
    }

    /// Only rows carrying the old name move: a row labeled with something else is untouched.
    func testOtherLabelsAreLeftAlone() throws {
        let (context, recording, v) = try makeStore()
        let other = VoiceRecording(audioFilename: "other-audio.m4a", durationS: 1)
        other.meaningTag = "Annoyed"
        context.insert(other)
        let tag = VoiceTag(kind: .meaning, name: "Hungry", isBuiltIn: true)
        context.insert(tag)
        try context.save()

        try VoiceTagRenamer.rename(tag: tag, to: "Wants food", context: context)

        XCTAssertEqual(other.meaningTag, "Annoyed")
        XCTAssertEqual(recording.meaningTag, "Wants food")
        XCTAssertEqual(v.meaningTag, "Wants food")
    }

    func testRenamingToTheSameNameDoesNothing() throws {
        let (context, _, _) = try makeStore()
        let tag = VoiceTag(kind: .meaning, name: "Hungry", isBuiltIn: true)
        context.insert(tag)
        try context.save()

        try VoiceTagRenamer.rename(tag: tag, to: "Hungry", context: context)
        XCTAssertEqual(tag.name, "Hungry")
    }
}
