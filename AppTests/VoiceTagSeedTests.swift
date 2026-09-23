import SwiftData
import XCTest
@testable import AnimalTracker

@MainActor
final class VoiceTagSeedTests: XCTestCase {
    func testSeedsOnceAndOnlyMissingNames() throws {
        let context = try TestSupport.container().mainContext
        context.insert(VoiceTag(kind: .meaning, name: "Hungry", isBuiltIn: true, sortOrder: 0))
        try context.save()
        let first = try VoiceTagSeed.seedIfNeeded(context: context)
        XCTAssertEqual(first, VoiceTagSeed.activities.count + VoiceTagSeed.meanings.count - 1)
        XCTAssertEqual(try VoiceTagSeed.seedIfNeeded(context: context), 0)
        let tags = try context.fetch(FetchDescriptor<VoiceTag>())
        XCTAssertEqual(tags.filter { $0.kind == .meaning }.count, VoiceTagSeed.meanings.count)
        XCTAssertTrue(VoiceTagSeed.meanings.contains(VoiceTagSeed.unknownMeaning))
        XCTAssertTrue(Seeds.all.count >= 1)
    }
}
