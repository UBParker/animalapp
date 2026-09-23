import Foundation

/// Acoustic features of one vocalization. Optional f0 fields are nil when fewer than 3 frames were voiced.
public struct VocalFeatures: Codable, Equatable {
    public var durationS: Double
    public var f0Mean: Double?
    public var f0Min: Double?
    public var f0Max: Double?
    /// Linear-fit slope of f0 over time, Hz per second. Positive = rising.
    public var f0Slope: Double?
    /// Fraction of pitch frames that were voiced (0 to 1).
    public var voicedFraction: Double
    public var rmsDb: Double
    public var spectralCentroidHz: Double
    /// 13 mean MFCCs.
    public var mfcc: [Double]

    public init(durationS: Double, f0Mean: Double?, f0Min: Double?, f0Max: Double?, f0Slope: Double?,
                voicedFraction: Double, rmsDb: Double, spectralCentroidHz: Double, mfcc: [Double]) {
        self.durationS = durationS
        self.f0Mean = f0Mean
        self.f0Min = f0Min
        self.f0Max = f0Max
        self.f0Slope = f0Slope
        self.voicedFraction = voicedFraction
        self.rmsDb = rmsDb
        self.spectralCentroidHz = spectralCentroidHz
        self.mfcc = mfcc
    }

    public static let mfccCount = 13

    /// Column names of `vector`, in order.
    public static let vectorColumns: [String] =
        ["durationS", "f0Mean", "f0Min", "f0Max", "f0Slope", "voicedFraction", "rmsDb", "spectralCentroidHz"]
        + (0..<mfccCount).map { "mfcc\($0)" }

    /// Fixed-order numeric vector for the stats package. Missing values are NaN.
    public var vector: [Double] {
        var v: [Double] = [durationS, f0Mean ?? .nan, f0Min ?? .nan, f0Max ?? .nan, f0Slope ?? .nan,
                           voicedFraction, rmsDb, spectralCentroidHz]
        v += (0..<Self.mfccCount).map { $0 < mfcc.count ? mfcc[$0] : .nan }
        return v
    }
}
