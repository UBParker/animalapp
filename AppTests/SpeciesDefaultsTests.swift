import XCTest
@testable import AnimalTracker

final class SpeciesDefaultsTests: XCTestCase {
    func testOutdoorSpecies() {
        for s in ["horse", "Pony", " donkey ", "goat", "sheep", "cow", "pig", "chicken"] {
            XCTAssertTrue(SpeciesDefaults.tracksOutdoorTime(s), s)
        }
        for s in ["dog", "cat", "rabbit", "other", "", "parrot"] {
            XCTAssertFalse(SpeciesDefaults.tracksOutdoorTime(s), s)
        }
    }

    func testSuggestionsOrder() {
        XCTAssertEqual(SpeciesDefaults.suggestions.first, "horse")
        XCTAssertEqual(SpeciesDefaults.suggestions.last, "other")
        XCTAssertEqual(SpeciesDefaults.suggestions.count, 12)
    }
}
