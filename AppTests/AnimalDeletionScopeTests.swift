import SwiftData
import XCTest
@testable import AnimalTracker

@MainActor
final class AnimalDeletionScopeTests: XCTestCase {
    /// One animal's recordings must never block a different animal's deletion.
    func testRecordCountsAreScopedToOneAnimal() throws {
        let context = try TestSupport.container().mainContext
        let withRecording = Animal(name: "Miso", species: "cat")
        let withoutRecording = Animal(name: "Rex", species: "dog")
        context.insert(withRecording)
        context.insert(withoutRecording)
        context.insert(VoiceRecording(audioFilename: "a-audio.m4a", durationS: 2, animal: withRecording))
        try context.save()

        XCTAssertEqual(try AnimalDeletionPolicy.recordCounts(for: withRecording, context: context)["voice recordings"], 1)
        XCTAssertEqual(try AnimalDeletionPolicy.recordCounts(for: withoutRecording, context: context)["voice recordings"], 0)
        XCTAssertFalse(try AnimalDeletionPolicy.canDelete(withRecording, context: context))
        XCTAssertTrue(try AnimalDeletionPolicy.canDelete(withoutRecording, context: context))
    }
}
