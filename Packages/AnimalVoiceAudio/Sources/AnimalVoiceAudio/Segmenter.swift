import Accelerate
import Foundation

public struct SegmenterConfig: Equatable, Sendable {
    public var frameSeconds: Double = 0.04
    public var hopSeconds: Double = 0.02
    public var relativeThresholdDb: Float = 20
    public var absoluteFloorDbfs: Float = -50
    public var minSegmentSeconds: Double = 0.08
    public var maxGapSeconds: Double = 0.10

    public init() {}
}

public struct Segment: Equatable, Codable, Sendable {
    public var startS: Double
    public var endS: Double

    public init(startS: Double, endS: Double) {
        self.startS = startS
        self.endS = endS
    }

    public var durationS: Double { endS - startS }
}

public enum Segmenter {
    /// RMS level in dBFS per frame. Frame i covers samples [i*hop, i*hop+frame).
    public static func frameRmsDb(_ buffer: AudioBuffer, config: SegmenterConfig = .init()) -> [Float] {
        let frame = Int(config.frameSeconds * buffer.sampleRate)
        let hop = Int(config.hopSeconds * buffer.sampleRate)
        guard buffer.samples.count >= frame, frame > 0, hop > 0 else { return [] }
        let n = 1 + (buffer.samples.count - frame) / hop
        var out = [Float](repeating: -160, count: n)
        buffer.samples.withUnsafeBufferPointer { p in
            for i in 0..<n {
                let slice = UnsafeBufferPointer(rebasing: p[(i * hop)..<(i * hop + frame)])
                let rms = vDSP.rootMeanSquare(slice)
                out[i] = 20 * log10(max(rms, 1e-8))
            }
        }
        return out
    }

    public static func segment(_ buffer: AudioBuffer, config: SegmenterConfig = .init()) -> [Segment] {
        let db = frameRmsDb(buffer, config: config)
        guard let peak = db.max() else { return [] }
        let threshold = max(peak - config.relativeThresholdDb, config.absoluteFloorDbfs)
        let active = db.map { $0 > threshold }

        // Runs of active frames as inclusive frame index ranges.
        var runs: [(Int, Int)] = []
        var start: Int?
        for (i, a) in active.enumerated() {
            if a, start == nil { start = i }
            if !a, let s = start { runs.append((s, i - 1)); start = nil }
        }
        if let s = start { runs.append((s, active.count - 1)) }

        // Bridge short gaps.
        let maxGapFrames = Int(config.maxGapSeconds / config.hopSeconds)
        var merged: [(Int, Int)] = []
        for r in runs {
            if let last = merged.last, r.0 - last.1 - 1 < maxGapFrames {
                merged[merged.count - 1].1 = r.1
            } else {
                merged.append(r)
            }
        }

        // Drop short runs and convert to seconds.
        let minFrames = Int((config.minSegmentSeconds / config.hopSeconds).rounded())
        return merged.compactMap { (a, b) in
            guard b - a + 1 >= minFrames else { return nil }
            let startS = Double(a) * config.hopSeconds
            let endS = Double(b) * config.hopSeconds + config.frameSeconds
            return Segment(startS: startS, endS: min(endS, buffer.durationS))
        }
    }
}
