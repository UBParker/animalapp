import XCTest
@testable import AnimalVoiceStats

final class ResearchPriorTests: XCTestCase {
    func testShortHighRising() {
        XCTAssertEqual(ResearchPrior.hint(species: "Cat", durationS: 0.4, f0Mean: 700, f0Slope: 200)?.hasPrefix("Short, high, rising"), true)
    }

    func testLongFalling() {
        XCTAssertEqual(ResearchPrior.hint(species: "domestic cat", durationS: 1.2, f0Mean: 400, f0Slope: -150)?.hasPrefix("Long and falling"), true)
    }

    func testNoPatternOrUnvoiced() {
        XCTAssertNil(ResearchPrior.hint(species: "Cat", durationS: 0.7, f0Mean: 600, f0Slope: 10))
        XCTAssertNil(ResearchPrior.hint(species: "Cat", durationS: 0.4, f0Mean: nil, f0Slope: nil))
    }

    func testOtherSpeciesGetNoHint() {
        XCTAssertNil(ResearchPrior.hint(species: "Dog", durationS: 0.4, f0Mean: 700, f0Slope: 200))
        XCTAssertNil(ResearchPrior.hint(species: "", durationS: 0.4, f0Mean: 700, f0Slope: 200))
    }

    func testAttributionMentionsMeowsic() {
        XCTAssertTrue(ResearchPrior.attribution.contains("Meowsic"))
    }
}
