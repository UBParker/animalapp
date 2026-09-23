import Foundation

/// Gaussian naive Bayes on standardized features, with a variance floor so tiny classes do not become overconfident.
public struct NaiveBayesClassifier {
    public var varianceFloor: Double

    public init(varianceFloor: Double = 0.01) {
        self.varianceFloor = varianceFloor
    }

    public func predict(query: [Double], training: [LabeledSample], standardizer: Standardizer) -> [String: Double] {
        guard !training.isEmpty else { return [:] }
        let q = standardizer.transform(query)
        let groups = Dictionary(grouping: training, by: \.label)
        let n = Double(training.count)
        var logPosterior: [String: Double] = [:]
        for (label, samples) in groups {
            let z = samples.map { standardizer.transform($0.features) }
            let m = Double(z.count)
            var lp = log(m / n)
            for j in 0..<q.count {
                let col = z.map { $0[j] }
                let mu = col.reduce(0, +) / m
                let variance = max(col.reduce(0) { $0 + ($1 - mu) * ($1 - mu) } / m, varianceFloor)
                lp += -0.5 * log(2 * .pi * variance) - (q[j] - mu) * (q[j] - mu) / (2 * variance)
            }
            logPosterior[label] = lp
        }
        let maxLog = logPosterior.values.max() ?? 0
        let unnormalized = logPosterior.mapValues { exp($0 - maxLog) }
        let total = unnormalized.values.reduce(0, +)
        return unnormalized.mapValues { $0 / total }
    }
}
