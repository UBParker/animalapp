import XCTest
@testable import AnimalVoiceStats

final class EnsembleTests: XCTestCase {
    func testAveragesAndKeepsNeighbors() {
        let training = TestData.clusters()
        let p = Ensemble().predict(query: [9, 9], training: training)
        XCTAssertEqual(p.best?.label, "b")
        XCTAssertGreaterThan(p.best?.probability ?? 0, 0.95)
        XCTAssertEqual(p.probabilities.values.reduce(0, +), 1, accuracy: 1e-9)
        XCTAssertEqual(p.neighborIds.count, 5)
        XCTAssertEqual(Set(p.probabilities.keys), ["a", "b"])
    }

    func testHandlesNaNInQueryAndTraining() {
        var training = TestData.clusters()
        training[0] = LabeledSample(id: training[0].id, features: [.nan, 0], label: "a")
        let p = Ensemble().predict(query: [.nan, 10], training: training)
        XCTAssertEqual(p.best?.label, "b")
        XCTAssertTrue(p.probabilities.values.allSatisfy { $0.isFinite })
    }
}
