import Foundation

public struct Evaluation: Equatable {
    public var accuracy: Double
    public var perClassRecall: [String: Double]
    public var n: Int

    public init(accuracy: Double, perClassRecall: [String: Double], n: Int) {
        self.accuracy = accuracy
        self.perClassRecall = perClassRecall
        self.n = n
    }
}

public enum Evaluator {
    /// Leave-one-out accuracy of the ensemble on an animal's labeled samples. Cheap for n in the hundreds.
    public static func leaveOneOut(_ samples: [LabeledSample], ensemble: Ensemble = Ensemble()) -> Evaluation {
        guard samples.count >= 2 else { return Evaluation(accuracy: 0, perClassRecall: [:], n: samples.count) }
        var correct = 0
        var totalByClass: [String: Int] = [:]
        var correctByClass: [String: Int] = [:]
        for i in samples.indices {
            var training = samples
            let held = training.remove(at: i)
            let prediction = ensemble.predict(query: held.features, training: training)
            totalByClass[held.label, default: 0] += 1
            if prediction.best?.label == held.label {
                correct += 1
                correctByClass[held.label, default: 0] += 1
            }
        }
        var recall: [String: Double] = [:]
        for (label, total) in totalByClass {
            recall[label] = Double(correctByClass[label] ?? 0) / Double(total)
        }
        return Evaluation(accuracy: Double(correct) / Double(samples.count), perClassRecall: recall, n: samples.count)
    }
}
