import Foundation

public enum ReadinessStatus: Equatable, Sendable {
    case ready(labels: [String])
    case notReady(message: String, needed: [String: Int])
}

/// Predictions are offered only when at least `minLabels` meanings each have `minPerLabel` labeled sounds.
public enum Readiness {
    public static let minPerLabel = 5
    public static let minLabels = 2

    public static func check(labelCounts: [String: Int]) -> ReadinessStatus {
        let readyLabels = labelCounts.filter { $0.value >= minPerLabel }.keys.sorted()
        if readyLabels.count >= minLabels {
            return .ready(labels: readyLabels)
        }
        let needed = labelCounts.filter { $0.value < minPerLabel }.mapValues { minPerLabel - $0 }
        let message: String
        if labelCounts.isEmpty {
            message = "No labeled sounds yet. Tag at least \(minPerLabel) sounds for each of \(minLabels) meanings."
        } else {
            message = "Not enough data yet: \(readyLabels.count) of \(minLabels) meanings have \(minPerLabel)+ labeled sounds."
        }
        return .notReady(message: message, needed: needed)
    }
}
