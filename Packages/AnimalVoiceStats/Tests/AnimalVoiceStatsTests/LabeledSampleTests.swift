import XCTest
@testable import AnimalVoiceStats

final class LabeledSampleTests: XCTestCase {
    func testInit() {
        let s = LabeledSample(features: [1, 2], label: "hungry")
        XCTAssertEqual(s.features, [1, 2])
        XCTAssertEqual(s.label, "hungry")
    }
}
