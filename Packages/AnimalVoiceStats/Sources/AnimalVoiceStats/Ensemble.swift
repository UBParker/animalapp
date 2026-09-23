import Foundation

/// Average of kNN and naive Bayes probabilities. Fits the standardizer on the training data each call; n is small.
public struct Ensemble {
    public var knn: KNNClassifier
    public var bayes: NaiveBayesClassifier

    public init(knn: KNNClassifier = KNNClassifier(), bayes: NaiveBayesClassifier = NaiveBayesClassifier()) {
        self.knn = knn
        self.bayes = bayes
    }

    public func predict(query: [Double], training: [LabeledSample]) -> Prediction {
        let standardizer = Standardizer.fit(training.map(\.features))
        let a = knn.predict(query: query, training: training, standardizer: standardizer)
        let b = bayes.predict(query: query, training: training, standardizer: standardizer)
        let labels = Set(a.probabilities.keys).union(b.keys)
        var probabilities: [String: Double] = [:]
        for label in labels {
            let pa: Double = a.probabilities[label] ?? 0
            let pb: Double = b[label] ?? 0
            probabilities[label] = 0.5 * pa + 0.5 * pb
        }
        return Prediction(probabilities: probabilities, neighborIds: a.neighborIds)
    }
}
