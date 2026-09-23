import XCTest
@testable import AnimalVoiceAudio

final class SpectralAnalyzerTests: XCTestCase {
    let analyzer = SpectralAnalyzer(sampleRate: 16_000)

    func testSpectrogramShape() {
        let mag = analyzer.magnitudeSpectrogram(TestSignals.sine(frequency: 1000, seconds: 1.0))
        XCTAssertEqual(mag.count, 51) // 1 + 16000 / 320 (librosa center=True)
        XCTAssertEqual(mag[0].count, 513)
    }

    func testCentroidOfPureTone() {
        let mag = analyzer.magnitudeSpectrogram(TestSignals.sine(frequency: 1000, seconds: 1.0))
        let c = analyzer.spectralCentroid(mag)
        let middle = c[5..<(c.count - 5)]
        let mean = middle.reduce(0, +) / Float(middle.count)
        XCTAssertEqual(mean, 1000, accuracy: 50)
    }

    func testCentroidOfSilenceIsZero() {
        let mag = analyzer.magnitudeSpectrogram(TestSignals.silence(seconds: 0.5))
        XCTAssertTrue(analyzer.spectralCentroid(mag).allSatisfy { $0 == 0 })
    }

    func testSlaneyMelRoundTrip() {
        for hz: Float in [50, 500, 1000, 2500, 7000] {
            XCTAssertEqual(SpectralAnalyzer.melToHz(SpectralAnalyzer.hzToMel(hz)), hz, accuracy: 0.01)
        }
        XCTAssertEqual(SpectralAnalyzer.hzToMel(1000), 15, accuracy: 1e-4) // 1000 / (200/3)
    }

    func testMelFilterbankShapeAndFirstBand() {
        let fb = SpectralAnalyzer.melFilterbank(sampleRate: 16_000, fftSize: 1024, melBands: 26)
        XCTAssertEqual(fb.count, 26)
        XCTAssertEqual(fb[0].count, 513)
        XCTAssertTrue(fb.allSatisfy { $0.reduce(0, +) > 0 })
        // First band peaks at melToHz(melMax/27) ~= 111.7 Hz -> bin 7 (bin width 15.625 Hz)
        let peakBin = fb[0].indices.max { fb[0][$0] < fb[0][$1] }!
        XCTAssertEqual(peakBin, 7)
    }

    func testDctIIOrtho() {
        let y = SpectralAnalyzer.dctII([1, 0, 0, 0])
        XCTAssertEqual(y[0], 0.5, accuracy: 1e-5)
        XCTAssertEqual(y[1], 0.65328, accuracy: 1e-4) // sqrt(2/4) * cos(pi/8)
    }

    func testMfccShape() {
        let mag = analyzer.magnitudeSpectrogram(TestSignals.sine(frequency: 1000, seconds: 0.5))
        let m = analyzer.mfcc(mag)
        XCTAssertEqual(m.count, mag.count)
        XCTAssertEqual(m[0].count, 13)
        XCTAssertTrue(m.flatMap { $0 }.allSatisfy { $0.isFinite })
    }
}
