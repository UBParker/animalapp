import Foundation

/// Column-wise z-scoring. NaN cells are ignored when fitting and map to 0 (the mean) when transforming.
public struct Standardizer: Equatable {
    public let means: [Double]
    public let stds: [Double]

    public init(means: [Double], stds: [Double]) {
        self.means = means
        self.stds = stds
    }

    public static func fit(_ rows: [[Double]]) -> Standardizer {
        guard let width = rows.first?.count else { return Standardizer(means: [], stds: []) }
        var means = [Double](repeating: 0, count: width)
        var stds = [Double](repeating: 1, count: width)
        for j in 0..<width {
            let col = rows.compactMap { $0.count > j && !$0[j].isNaN ? $0[j] : nil }
            guard !col.isEmpty else { continue }
            let m = col.reduce(0, +) / Double(col.count)
            let v = col.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(col.count)
            means[j] = m
            let sd = v.squareRoot()
            stds[j] = sd > 1e-9 ? sd : 1
        }
        return Standardizer(means: means, stds: stds)
    }

    public func transform(_ row: [Double]) -> [Double] {
        (0..<means.count).map { j in
            guard j < row.count, !row[j].isNaN else { return 0 }
            return (row[j] - means[j]) / stds[j]
        }
    }
}
