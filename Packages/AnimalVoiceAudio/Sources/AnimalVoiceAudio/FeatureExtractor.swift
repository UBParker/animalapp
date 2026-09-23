import Foundation

public enum FeatureExtractor {
    public static let minVoicedFrames = 3

    /// Features for one segment of a buffer.
    public static func features(_ buffer: AudioBuffer, segment: Segment,
                                pitch: PitchConfig = .init(), spectral: SpectralConfig = .init()) -> VocalFeatures {
        let samples = Array(buffer.slice(startS: segment.startS, endS: segment.endS))
        let sr = buffer.sampleRate

        // Pitch statistics.
        let frames = PitchTracker.track(samples, sampleRate: sr, config: pitch)
        let voiced = frames.compactMap { frame in frame.f0Hz.map { (t: frame.timeS, f0: $0) } }
        let voicedFraction = frames.isEmpty ? 0 : Double(voiced.count) / Double(frames.count)
        var f0Mean: Double?, f0Min: Double?, f0Max: Double?, f0Slope: Double?
        let usable = rejectingOctaveOutliers(voiced)
        if usable.count >= minVoicedFrames {
            let f0s = usable.map(\.f0)
            f0Mean = f0s.reduce(0, +) / Double(f0s.count)
            f0Min = f0s.min()
            f0Max = f0s.max()
            f0Slope = linearSlope(x: usable.map(\.t), y: f0s)
        }

        // Loudness.
        let meanSquare = samples.isEmpty ? 0 : samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)
        let rmsDb = 20 * log10(max(meanSquare.squareRoot(), 1e-8))

        // Spectral shape.
        let analyzer = SpectralAnalyzer(sampleRate: sr, config: spectral)
        let mag = analyzer.magnitudeSpectrogram(samples)
        let centroid = analyzer.spectralCentroid(mag)
        let centroidMean = centroid.isEmpty ? 0 : Double(centroid.reduce(0, +)) / Double(centroid.count)
        let mfccFrames = analyzer.mfcc(mag)
        var mfccMean = [Double](repeating: 0, count: spectral.mfccCount)
        if !mfccFrames.isEmpty {
            for frame in mfccFrames {
                for (i, v) in frame.enumerated() { mfccMean[i] += Double(v) }
            }
            mfccMean = mfccMean.map { $0 / Double(mfccFrames.count) }
        }

        return VocalFeatures(durationS: segment.durationS, f0Mean: f0Mean, f0Min: f0Min, f0Max: f0Max,
                             f0Slope: f0Slope, voicedFraction: voicedFraction, rmsDb: rmsDb,
                             spectralCentroidHz: centroidMean, mfcc: mfccMean)
    }

    /// Segment a whole buffer and extract features for each event.
    public static func analyze(_ buffer: AudioBuffer, segmenter: SegmenterConfig = .init()) -> [(segment: Segment, features: VocalFeatures)] {
        Segmenter.segment(buffer, config: segmenter).map { ($0, features(buffer, segment: $0)) }
    }

    /// Drops frames more than an octave from the median voiced f0 before the f0 statistics.
    /// YIN occasionally locks onto a short lag for a single frame (a 2.3 kHz frame amid 400 Hz ones),
    /// and one such frame moves an arithmetic mean by tens of percent. Voicing itself is left alone:
    /// `voicedFraction` still counts every frame YIN called periodic.
    static func rejectingOctaveOutliers(_ voiced: [(t: Double, f0: Double)]) -> [(t: Double, f0: Double)] {
        guard voiced.count >= minVoicedFrames else { return voiced }
        let sorted = voiced.map(\.f0).sorted()
        let mid = sorted.count / 2
        let median = sorted.count % 2 == 1 ? sorted[mid] : 0.5 * (sorted[mid - 1] + sorted[mid])
        guard median > 0 else { return voiced }
        let kept = voiced.filter { $0.f0 >= median / 2 && $0.f0 <= median * 2 }
        return kept.count >= minVoicedFrames ? kept : voiced
    }

    static func linearSlope(x: [Double], y: [Double]) -> Double {
        let n = Double(x.count)
        guard n > 1 else { return 0 }
        let mx = x.reduce(0, +) / n
        let my = y.reduce(0, +) / n
        var num = 0.0, den = 0.0
        for i in 0..<x.count {
            num += (x[i] - mx) * (y[i] - my)
            den += (x[i] - mx) * (x[i] - mx)
        }
        return den > 0 ? num / den : 0
    }
}
