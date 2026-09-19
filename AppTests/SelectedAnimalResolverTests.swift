import XCTest
@testable import AnimalTracker

final class SelectedAnimalResolverTests: XCTestCase {
    private func snap(_ name: String, order: Int, archived: Bool = false) -> AnimalSnapshot {
        AnimalSnapshot(id: UUID(), name: name, species: "dog", tracksOutdoorTime: false, isArchived: archived, sortOrder: order)
    }

    func testStoredIdWins() {
        let a = snap("A", order: 1), b = snap("B", order: 0)
        XCTAssertEqual(SelectedAnimalResolver.resolve(storedID: a.id.uuidString, animals: [a, b]), a.id)
    }

    func testArchivedOrMissingFallsBackToFirstActiveBySortOrder() {
        let archived = snap("Old", order: 0, archived: true), a = snap("A", order: 2), b = snap("B", order: 1)
        XCTAssertEqual(SelectedAnimalResolver.resolve(storedID: archived.id.uuidString, animals: [archived, a, b]), b.id)
        XCTAssertEqual(SelectedAnimalResolver.resolve(storedID: UUID().uuidString, animals: [a, b]), b.id)
        XCTAssertEqual(SelectedAnimalResolver.resolve(storedID: "", animals: [a, b]), b.id)
    }

    func testNoActiveAnimals() {
        XCTAssertNil(SelectedAnimalResolver.resolve(storedID: "", animals: []))
        XCTAssertNil(SelectedAnimalResolver.resolve(storedID: "", animals: [snap("Old", order: 0, archived: true)]))
    }
}
