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

    /// The in-memory store answers a `#Predicate` over an optional String in Swift, so it cannot
    /// tell whether that predicate translates to SQL. This runs the same rename against a real
    /// on-disk store, then reads the rows back through a fresh context so the assertions come from
    /// SQLite rather than from the objects already registered in the writing context.
    func testRenamingAnActivityMigratesLabelsInAnOnDiskStore() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "rename-on-disk-\(UUID().uuidString).store")
        defer { PersistenceController.destroy(url: url) }
        let container = try PersistenceController.makeContainer(inMemory: false, url: url)
        let context = container.mainContext

        let eating = VoiceRecording(audioFilename: "eating.m4a", durationS: 1)
        eating.activityTag = "Eating"
        context.insert(eating)
        let playing = VoiceRecording(audioFilename: "playing.m4a", durationS: 1)
        playing.activityTag = "Playing"
        context.insert(playing)

        let eatingSound = Vocalization(segment: Segment(startS: 0, endS: 0.4), features: VoiceFixtures.features())
        eatingSound.activityTag = "Eating"
        eatingSound.recording = eating
        context.insert(eatingSound)
        let playingSound = Vocalization(segment: Segment(startS: 0, endS: 0.4), features: VoiceFixtures.features())
        playingSound.activityTag = "Playing"
        playingSound.recording = playing
        context.insert(playingSound)

        let tag = VoiceTag(kind: .activity, name: "Eating", isBuiltIn: true)
        context.insert(tag)
        try context.save()

        try VoiceTagRenamer.rename(tag: tag, to: "Snacking", context: context)

        let fresh = ModelContext(container)
        let recordings = try fresh.fetch(FetchDescriptor<VoiceRecording>())
        let sounds = try fresh.fetch(FetchDescriptor<Vocalization>())
        XCTAssertEqual(recordings.filter { $0.activityTag == "Snacking" }.count, 1)
        XCTAssertEqual(sounds.filter { $0.activityTag == "Snacking" }.count, 1)
        XCTAssertTrue(recordings.allSatisfy { $0.activityTag != "Eating" }, "no row keeps the old name")
        XCTAssertTrue(sounds.allSatisfy { $0.activityTag != "Eating" })
        XCTAssertEqual(recordings.filter { $0.activityTag == "Playing" }.count, 1, "another activity is untouched")
        XCTAssertEqual(sounds.filter { $0.activityTag == "Playing" }.count, 1)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<VoiceTag>()).map(\.name), ["Snacking"])
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
