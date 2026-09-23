import Accelerate
import Foundation

public struct PitchConfig: Equatable, Sendable {
    public var frameSeconds: Double = 0.04
    public var hopSeconds: Double = 0.02
    public var minHz: Double = 60
    public var maxHz: Double = 3000
    /// CMNDF value below which a lag counts as periodic (de Cheveigné & Kawahara 2002 use 0.1; 0.3 is more permissive for noisy phone audio).
    public var threshold: Float = 0.3

    public init() {}
}

public struct PitchFrame: Equatable {
    /// Start time of the frame in seconds.
    public var timeS: Double
    /// Fundamental frequency, nil when the frame is unvoiced.
    public var f0Hz: Double?
    /// Minimum cumulative-mean-normalized difference in the search range (0 = perfectly periodic).
    public var aperiodicity: Float
}

/// YIN pitch estimation: difference function -> cumulative mean normalization -> absolute threshold -> parabolic interpolation.
public enum PitchTracker {
    public static func track(_ samples: [Float], sampleRate: Double, config: PitchConfig = .init()) -> [PitchFrame] {
        let w = Int(config.frameSeconds * sampleRate)
        let hop = Int(config.hopSeconds * sampleRate)
        let tauMin = max(2, Int(sampleRate / config.maxHz))
        let tauMax = Int(sampleRate / config.minHz)
        guard w > 0, hop > 0, tauMax > tauMin, samples.count >= w else { return [] }

        // Pad so every frame can look tauMax samples ahead.
        let padded = samples + [Float](repeating: 0, count: tauMax + 1)
        let frameCount = 1 + (samples.count - w) / hop
        var frames: [PitchFrame] = []
        frames.reserveCapacity(frameCount)
        var scratch = [Float](repeating: 0, count: w)

        padded.withUnsafeBufferPointer { p in
            for i in 0..<frameCount {
                let start = i * hop
                let (lag, aperiodicity) = yin(p, start: start, window: w, tauMin: tauMin, tauMax: tauMax,
                                              threshold: config.threshold, scratch: &scratch)
                frames.append(PitchFrame(timeS: Double(start) / sampleRate,
                                         f0Hz: lag.map { sampleRate / Double($0) },
                                         aperiodicity: aperiodicity))
            }
        }
        return frames
    }

    /// One YIN frame. Returns (refined lag in samples or nil if unvoiced, aperiodicity).
    static func yin(_ p: UnsafeBufferPointer<Float>, start: Int, window w: Int, tauMin: Int, tauMax: Int,
                    threshold: Float, scratch: inout [Float]) -> (Float?, Float) {
        let x = UnsafeBufferPointer(rebasing: p[start..<(start + w)])
        var d = [Float](repeating: 0, count: tauMax + 1)
        for tau in 1...tauMax {
            let y = UnsafeBufferPointer(rebasing: p[(start + tau)..<(start + tau + w)])
            vDSP.subtract(x, y, result: &scratch)
            d[tau] = vDSP.sumOfSquares(scratch)
        }

        // Cumulative mean normalized difference function.
        var dp = [Float](repeating: 1, count: tauMax + 1)
        var running: Float = 0
        for tau in 1...tauMax {
            running += d[tau]
            dp[tau] = running > 0 ? d[tau] * Float(tau) / running : 1
        }

        // First dip below threshold, then slide to its local minimum.
        var tau = tauMin
        var found: Int?
        while tau <= tauMax {
            if dp[tau] < threshold {
                while tau + 1 <= tauMax, dp[tau + 1] < dp[tau] { tau += 1 }
                found = tau
                break
            }
            tau += 1
        }
        guard let t = found else {
            return (nil, dp[tauMin...tauMax].min() ?? 1)
        }

        // Parabolic interpolation around the minimum.
        var refined = Float(t)
        if t > 1, t < tauMax {
            let a = dp[t - 1], b = dp[t], c = dp[t + 1]
            let denom = a - 2 * b + c
            if abs(denom) > 1e-9 { refined += 0.5 * (a - c) / denom }
        }
        return (refined, dp[t])
    }
}
