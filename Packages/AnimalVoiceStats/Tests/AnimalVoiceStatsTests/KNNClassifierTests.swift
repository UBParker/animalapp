import XCTest
@testable import AnimalVoiceStats

enum TestData {
    /// Two well-separated clusters in 2-D: "a" around (0, 0), "b" around (10, 10). Deterministic jitter.
    static func clusters(perClass n: Int = 8) -> [LabeledSample] {
        var out: [LabeledSample] = []
        for i in 0..<n {
            let j = Double(i % 4) * 0.25
            out.append(LabeledSample(features: [0 + j, 0 - j], label: "a"))
            out.append(LabeledSample(features: [10 + j, 10 - j], label: "b"))
        }
        return out
    }
}

final class KNNClassifierTests: XCTestCase {
    func testPredictsNearestCluster() {
        let training = TestData.clusters()
        let st = Standardizer.fit(training.map(\.features))
        let p = KNNClassifier(k: 5).predict(query: [0.5, 0.5], training: training, standardizer: st)
        XCTAssertEqual(p.best?.label, "a")
        XCTAssertGreaterThan(p.best?.probability ?? 0, 0.99)
        XCTAssertEqual(p.neighborIds.count, 5)
        let byId = Dictionary(uniqueKeysWithValues: training.map { ($0.id, $0.label) })
        XCTAssertTrue(p.neighborIds.allSatisfy { byId[$0] == "a" })
    }

    func testMidpointIsUncertain() {
        let training = TestData.clusters()
        let st = Standardizer.fit(training.map(\.features))
        let p = KNNClassifier(k: 8).predict(query: [5, 5], training: training, standardizer: st)
        XCTAssertEqual(p.probabilities["a"] ?? 0, 0.5, accuracy: 0.2)
    }

    func testEmptyTraining() {
        let p = KNNClassifier().predict(query: [1, 2], training: [], standardizer: Standardizer(means: [0, 0], stds: [1, 1]))
        XCTAssertTrue(p.probabilities.isEmpty)
        XCTAssertNil(p.best)
    }

    func testKLargerThanTrainingUsesAll() {
        let training = Array(TestData.clusters().prefix(3))
        let st = Standardizer.fit(training.map(\.features))
        let p = KNNClassifier(k: 5).predict(query: [0, 0], training: training, standardizer: st)
        XCTAssertEqual(p.neighborIds.count, 3)
        XCTAssertEqual(p.probabilities.values.reduce(0, +), 1, accuracy: 1e-9)
    }
}
