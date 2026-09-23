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

    /// The two halves disagree on this training set, so the ensemble's number can only come from
    /// averaging both: each half on its own lands further than the tolerance from the mean.
    func testAveragesTwoDisagreeingClassifiers() {
        let training =
            [-5.0, -4, -3, -2, 2, 3, 4, 5].map { LabeledSample(features: [$0], label: "a") }
            + [1.2, 1.25, 1.3].map { LabeledSample(features: [$0], label: "b") }
        let query = [0.5]
        let standardizer = Standardizer.fit(training.map(\.features))
        let knn = KNNClassifier().predict(query: query, training: training, standardizer: standardizer)
        let bayes = NaiveBayesClassifier().predict(query: query, training: training, standardizer: standardizer)
        let bayesBest = bayes.sorted { $0.key < $1.key }.max { $0.value < $1.value }?.key
        XCTAssertNotEqual(knn.best?.label, bayesBest, "the halves must disagree for this test to discriminate")

        let p = Ensemble().predict(query: query, training: training)
        for label in ["a", "b"] {
            let mean = 0.5 * ((knn.probabilities[label] ?? 0) + (bayes[label] ?? 0))
            XCTAssertEqual(p.probabilities[label] ?? 0, mean, accuracy: 0.05, "\(label) is the mean of the two halves")
            XCTAssertGreaterThan(abs((knn.probabilities[label] ?? 0) - mean), 0.05, "a kNN-only ensemble would fail the check above")
            XCTAssertGreaterThan(abs((bayes[label] ?? 0) - mean), 0.05, "a Bayes-only ensemble would fail the check above")
        }
    }
}
