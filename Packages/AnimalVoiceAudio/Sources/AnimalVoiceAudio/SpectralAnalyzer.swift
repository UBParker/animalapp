import Accelerate
import Foundation

public struct SpectralConfig: Equatable {
    public var fftSize = 1024
    public var hop = 320
    public var melBands = 26
    public var mfccCount = 13
    public var topDb: Float = 80

    public init() {}
}

/// STFT-based features that mirror librosa defaults so the Python oracle can check them.
public final class SpectralAnalyzer {
    public let sampleRate: Double
    public let config: SpectralConfig
    private let dft: vDSP.DFT<Float>
    private let window: [Float]
    private let melFilters: [[Float]]
    private let binHz: [Float]

    public init(sampleRate: Double, config: SpectralConfig = .init()) {
        self.sampleRate = sampleRate
        self.config = config
        let n = config.fftSize
        dft = vDSP.DFT(count: n, direction: .forward, transformType: .complexComplex, ofType: Float.self)!
        // Periodic Hann, same as scipy.signal.get_window("hann", n, fftbins=True).
        window = (0..<n).map { 0.5 - 0.5 * cos(2 * Float.pi * Float($0) / Float(n)) }
        binHz = (0...(n / 2)).map { Float($0) * Float(sampleRate) / Float(n) }
        melFilters = Self.melFilterbank(sampleRate: sampleRate, fftSize: n, melBands: config.melBands)
    }

    public var binCount: Int { config.fftSize / 2 + 1 }

    /// Magnitude spectrogram (frames x bins). Zero-pads fftSize/2 on both sides like librosa center=True, pad_mode="constant".
    public func magnitudeSpectrogram(_ samples: [Float]) -> [[Float]] {
        let n = config.fftSize
        let pad = n / 2
        let x = [Float](repeating: 0, count: pad) + samples + [Float](repeating: 0, count: pad)
        guard x.count >= n else { return [] }
        let frameCount = 1 + (x.count - n) / config.hop
        let zeros = [Float](repeating: 0, count: n)
        var re = [Float](repeating: 0, count: n)
        var im = [Float](repeating: 0, count: n)
        var out: [[Float]] = []
        out.reserveCapacity(frameCount)
        for t in 0..<frameCount {
            let s = t * config.hop
            let frame = vDSP.multiply(Array(x[s..<(s + n)]), window)
            dft.transform(inputReal: frame, inputImaginary: zeros, outputReal: &re, outputImaginary: &im)
            var mag = [Float](repeating: 0, count: binCount)
            for k in 0..<binCount { mag[k] = (re[k] * re[k] + im[k] * im[k]).squareRoot() }
            out.append(mag)
        }
        return out
    }

    /// Per-frame spectral centroid in Hz (librosa.feature.spectral_centroid on a magnitude spectrogram).
    public func spectralCentroid(_ mag: [[Float]]) -> [Float] {
        mag.map { m in
            let total = vDSP.sum(m)
            return total > 0 ? vDSP.dot(m, binHz) / total : 0
        }
    }

    /// Per-frame MFCCs: power spectrum -> slaney mel bands -> 10*log10 with top_db clipping -> DCT-II ortho -> first mfccCount.
    public func mfcc(_ mag: [[Float]]) -> [[Float]] {
        guard !mag.isEmpty else { return [] }
        var logMel: [[Float]] = mag.map { m in
            let power = vDSP.multiply(m, m)
            return melFilters.map { f in 10 * log10(max(vDSP.dot(f, power), 1e-10)) }
        }
        let peak = logMel.flatMap { $0 }.max() ?? 0
        let floorDb = peak - config.topDb
        logMel = logMel.map { row in row.map { max($0, floorDb) } }
        return logMel.map { Array(Self.dctII($0).prefix(config.mfccCount)) }
    }

    // MARK: - Slaney mel scale (librosa htk=False)

    private static let fSp: Float = 200.0 / 3
    private static let minLogHz: Float = 1000
    private static let minLogMel: Float = 1000 / (200.0 / 3)
    private static let logStep: Float = Float(log(6.4)) / 27

    static func hzToMel(_ hz: Float) -> Float {
        hz < minLogHz ? hz / fSp : minLogMel + log(hz / minLogHz) / logStep
    }

    static func melToHz(_ mel: Float) -> Float {
        mel < minLogMel ? mel * fSp : minLogHz * exp(logStep * (mel - minLogMel))
    }

    /// librosa.filters.mel(sr, n_fft, n_mels, fmin=0, fmax=sr/2, htk=False, norm="slaney"). Returns bands x bins.
    static func melFilterbank(sampleRate: Double, fftSize: Int, melBands: Int) -> [[Float]] {
        let bins = fftSize / 2 + 1
        let fftHz = (0..<bins).map { Float($0) * Float(sampleRate) / Float(fftSize) }
        let melMin = hzToMel(0)
        let melMax = hzToMel(Float(sampleRate) / 2)
        let melPoints = (0..<(melBands + 2)).map { melToHz(melMin + (melMax - melMin) * Float($0) / Float(melBands + 1)) }
        var filters: [[Float]] = []
        for i in 0..<melBands {
            let lower = melPoints[i], center = melPoints[i + 1], upper = melPoints[i + 2]
            let enorm = 2 / (upper - lower)
            filters.append(fftHz.map { f in
                let up = (f - lower) / (center - lower)
                let down = (upper - f) / (upper - center)
                return max(0, min(up, down)) * enorm
            })
        }
        return filters
    }

    /// scipy.fftpack.dct(x, type=2, norm="ortho")
    static func dctII(_ x: [Float]) -> [Float] {
        let n = x.count
        guard n > 0 else { return [] }
        return (0..<n).map { k in
            var acc: Float = 0
            for i in 0..<n {
                acc += x[i] * cos(Float.pi * Float(k) * (2 * Float(i) + 1) / (2 * Float(n)))
            }
            let scale: Float = k == 0 ? (1 / Float(n)).squareRoot() : (2 / Float(n)).squareRoot()
            return scale * acc
        }
    }
}
