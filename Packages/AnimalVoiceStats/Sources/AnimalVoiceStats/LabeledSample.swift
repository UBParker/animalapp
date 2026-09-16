import Foundation

/// One labeled vocalization: a fixed-order feature vector (NaN = missing) and its meaning label.
public struct LabeledSample: Equatable {
    public let id: UUID
    public let features: [Double]
    public let label: String

    public init(id: UUID = UUID(), features: [Double], label: String) {
        self.id = id
        self.features = features
        self.label = label
    }
}
