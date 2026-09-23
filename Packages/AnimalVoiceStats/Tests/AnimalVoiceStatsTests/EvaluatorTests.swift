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

    /// The only "c" sample is the one held out on its own fold, so "c" is not in the training set
    /// and cannot be predicted: its recall is 0. Leaking the held-out sample would make it 1.
    func testSingletonClassScoresZeroRecall() {
        var samples = TestData.clusters(perClass: 6)
        samples.append(LabeledSample(features: [5, 5], label: "c"))
        let e = Evaluator.leaveOneOut(samples)
        XCTAssertEqual(e.n, 13)
        XCTAssertEqual(e.perClassRecall["c"], 0, "a singleton class can never be predicted on its own fold")
        XCTAssertEqual(e.perClassRecall.count, 3, "the singleton class is still scored")
    }
}
