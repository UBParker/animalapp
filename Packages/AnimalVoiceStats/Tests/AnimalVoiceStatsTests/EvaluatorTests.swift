import XCTest
@testable import AnimalVoiceStats

final class EvaluatorTests: XCTestCase {
    func testSeparableDataScoresHigh() {
        let e = Evaluator.leaveOneOut(TestData.clusters())
        XCTAssertEqual(e.n, 16)
        XCTAssertGreaterThan(e.accuracy, 0.9)
        XCTAssertGreaterThan(e.perClassRecall["a"] ?? 0, 0.9)
        XCTAssertGreaterThan(e.perClassRecall["b"] ?? 0, 0.9)
    }

    func testFewerThanTwoSamplesIsZero() {
        let e = Evaluator.leaveOneOut([LabeledSample(features: [1], label: "a")])
        XCTAssertEqual(e.accuracy, 0)
        XCTAssertEqual(e.n, 1)
    }
}
