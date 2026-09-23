import XCTest
@testable import AnimalVoiceStats

final class NaiveBayesClassifierTests: XCTestCase {
    func testSeparableClusters() {
        let training = TestData.clusters()
        let st = Standardizer.fit(training.map(\.features))
        let p = NaiveBayesClassifier().predict(query: [1, 1], training: training, standardizer: st)
        XCTAssertGreaterThan(p["a"] ?? 0, 0.99)
        XCTAssertEqual(p.values.reduce(0, +), 1, accuracy: 1e-9)
    }

    func testSingleClassIsCertain() {
        let training = TestData.clusters().filter { $0.label == "a" }
        let st = Standardizer.fit(training.map(\.features))
        let p = NaiveBayesClassifier().predict(query: [50, 50], training: training, standardizer: st)
        XCTAssertEqual(p["a"] ?? 0, 1, accuracy: 1e-9)
    }

    func testEmptyTraining() {
        XCTAssertTrue(NaiveBayesClassifier().predict(query: [1], training: [], standardizer: Standardizer(means: [0], stds: [1])).isEmpty)
    }
}
