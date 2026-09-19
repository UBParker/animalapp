import XCTest
@testable import AnimalTracker

@MainActor
final class AnimalDeletionPolicyTests: XCTestCase {
    func testFreshAnimalIsDeletable() throws {
        let context = try TestSupport.container().mainContext
        let a = Animal(name: "Juniper", species: "horse")
        context.insert(a)
        XCTAssertEqual(try AnimalDeletionPolicy.recordCounts(for: a, context: context).values.reduce(0, +), 0)
        XCTAssertTrue(try AnimalDeletionPolicy.canDelete(a, context: context))
    }
}
