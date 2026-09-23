import Foundation

public struct Prediction: Equatable {
    /// Probability per label, sums to 1 (empty when there is no training data).
    public var probabilities: [String: Double]
    /// Ids of the nearest training samples, closest first.
    public var neighborIds: [UUID]

    public init(probabilities: [String: Double], neighborIds: [UUID]) {
        self.probabilities = probabilities
        self.neighborIds = neighborIds
    }

    /// Highest-probability label; ties broken alphabetically so results are stable.
    public var best: (label: String, probability: Double)? {
        probabilities.sorted { $0.key < $1.key }.max { $0.value < $1.value }.map { ($0.key, $0.value) }
    }
}

/// Distance-weighted k-nearest-neighbors on standardized features.
public struct KNNClassifier {
    public var k: Int

    public init(k: Int = 5) {
        self.k = k
    }

    public func predict(query: [Double], training: [LabeledSample], standardizer: Standardizer) -> Prediction {
        guard !training.isEmpty else { return Prediction(probabilities: [:], neighborIds: []) }
        let q = standardizer.transform(query)
        let scored = training
            .map { sample -> (LabeledSample, Double) in
                let z = standardizer.transform(sample.features)
                let d = zip(q, z).reduce(0.0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }.squareRoot()
                return (sample, d)
            }
            .sorted { ($0.1, $0.0.id.uuidString) < ($1.1, $1.0.id.uuidString) }
        let nearest = scored.prefix(max(1, k))
        var weights: [String: Double] = [:]
        for (sample, d) in nearest {
            weights[sample.label, default: 0] += 1 / (d + 1e-6)
        }
        let total = weights.values.reduce(0, +)
        return Prediction(probabilities: weights.mapValues { $0 / total }, neighborIds: nearest.map { $0.0.id })
    }
}
