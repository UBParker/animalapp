import Foundation

/// Mono Float32 audio in memory.
public struct AudioBuffer: Equatable {
    public var samples: [Float]
    public var sampleRate: Double

    public init(samples: [Float], sampleRate: Double) {
        self.samples = samples
        self.sampleRate = sampleRate
    }

    public var durationS: Double { Double(samples.count) / sampleRate }

    /// Samples between two times, clamped to the buffer.
    public func slice(startS: Double, endS: Double) -> ArraySlice<Float> {
        let a = max(0, Int(startS * sampleRate))
        let b = min(samples.count, Int(endS * sampleRate))
        guard b > a else { return [] }
        return samples[a..<b]
    }
}
