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

    /// The old install-scoped UserDefaults flag must not stop a fresh store from being seeded:
    /// a store recreated after a reset would otherwise come up with no tags at all.
    func testRunSeedsAFreshStoreEvenWhenTheOldFlagIsSet() throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: VoiceTagSeed.seededKey)
        defaults.set(true, forKey: VoiceTagSeed.seededKey)
        defer {
            if let previous { defaults.set(previous, forKey: VoiceTagSeed.seededKey) }
            else { defaults.removeObject(forKey: VoiceTagSeed.seededKey) }
        }

        let context = try TestSupport.container().mainContext
        VoiceTagSeed.run(context)
        let tags = try context.fetch(FetchDescriptor<VoiceTag>())
        XCTAssertEqual(tags.count, VoiceTagSeed.activities.count + VoiceTagSeed.meanings.count)
    }

    func testBuiltInIDIsStableAndDiffersPerKindAndName() {
        let hungry = VoiceTagSeed.builtInID(kind: .meaning, name: "Hungry")
        XCTAssertEqual(hungry, VoiceTagSeed.builtInID(kind: .meaning, name: "Hungry"), "same input, same id")
        XCTAssertNotEqual(hungry, VoiceTagSeed.builtInID(kind: .activity, name: "Hungry"), "kind is part of the name")
        XCTAssertNotEqual(hungry, VoiceTagSeed.builtInID(kind: .meaning, name: "Greeting"))
        XCTAssertEqual(hungry.uuid.6 & 0xF0, 0x50, "version 5")
        XCTAssertEqual(hungry.uuid.8 & 0xC0, 0x80, "RFC 4122 variant")
    }

    func testSeedingTwiceProducesNoDuplicates() throws {
        let context = try TestSupport.container().mainContext
        VoiceTagSeed.run(context)
        VoiceTagSeed.run(context)
        let tags = try context.fetch(FetchDescriptor<VoiceTag>())
        XCTAssertEqual(tags.count, VoiceTagSeed.activities.count + VoiceTagSeed.meanings.count)
        XCTAssertEqual(Set(tags.map(\.id)).count, tags.count, "ids are unique")
        XCTAssertEqual(Set(tags.map { "\($0.kindRaw):\($0.name)" }).count, tags.count, "kind and name are unique")
        XCTAssertEqual(tags.first { $0.kind == .meaning && $0.name == "Hungry" }?.id,
                       VoiceTagSeed.builtInID(kind: .meaning, name: "Hungry"))
    }
}
