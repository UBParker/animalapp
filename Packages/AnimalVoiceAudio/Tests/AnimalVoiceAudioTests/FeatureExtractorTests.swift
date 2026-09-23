import XCTest
@testable import AnimalVoiceAudio

final class FeatureExtractorTests: XCTestCase {
    /// Linear chirp from f0 to f1 over `seconds`.
    private func chirp(from f0: Double, to f1: Double, seconds: Double, sr: Double = 16_000) -> [Float] {
        let n = Int(seconds * sr)
        var phase = 0.0
        return (0..<n).map { i in
            let f = f0 + (f1 - f0) * Double(i) / Double(n)
            phase += 2 * .pi * f / sr
            return 0.5 * Float(sin(phase))
        }
    }

    func testRisingChirpHasPositiveSlope() {
        let b = AudioBuffer(samples: chirp(from: 300, to: 600, seconds: 0.5), sampleRate: 16_000)
        let f = FeatureExtractor.features(b, segment: Segment(startS: 0, endS: 0.5))
        XCTAssertEqual(f.durationS, 0.5, accuracy: 1e-9)
        XCTAssertGreaterThan(f.voicedFraction, 0.8)
        XCTAssertEqual(f.f0Mean ?? 0, 450, accuracy: 45)
        XCTAssertGreaterThan(f.f0Slope ?? 0, 300) // Hz per second, nominal 600
        XCTAssertLessThan(f.f0Min ?? 0, f.f0Max ?? 0)
        XCTAssertEqual(f.rmsDb, -9.0, accuracy: 0.5) // amplitude 0.5 sine
        XCTAssertEqual(f.mfcc.count, 13)
    }

    func testSilenceIsUnvoiced() {
        let b = AudioBuffer(samples: TestSignals.silence(seconds: 0.5), sampleRate: 16_000)
        let f = FeatureExtractor.features(b, segment: Segment(startS: 0, endS: 0.5))
        XCTAssertNil(f.f0Mean)
        XCTAssertNil(f.f0Slope)
        XCTAssertEqual(f.voicedFraction, 0)
        XCTAssertEqual(f.spectralCentroidHz, 0)
    }

    func testVectorLayout() {
        let f = VocalFeatures(durationS: 0.3, f0Mean: nil, f0Min: nil, f0Max: nil, f0Slope: nil,
                              voicedFraction: 0, rmsDb: -20, spectralCentroidHz: 1500, mfcc: Array(repeating: 1, count: 13))
        XCTAssertEqual(VocalFeatures.vectorColumns.count, 21)
        XCTAssertEqual(f.vector.count, 21)
        XCTAssertEqual(f.vector[0], 0.3)
        XCTAssertTrue(f.vector[1].isNaN && f.vector[4].isNaN)
        XCTAssertEqual(f.vector[7], 1500)
        XCTAssertEqual(f.vector[8], 1)
        XCTAssertEqual(VocalFeatures.vectorColumns[8], "mfcc0")
    }

    func testAnalyzeSegmentsAndExtracts() throws {
        let b = try AudioLoader.load(TestSignals.fixtureURL("cat1_16k.wav"))
        let results = FeatureExtractor.analyze(b)
        XCTAssertTrue((10...14).contains(results.count))
        XCTAssertTrue(results.allSatisfy { $0.features.mfcc.count == 13 })
    }

    struct Oracle: Decodable {
        struct Seg: Decodable {
            let startS: Double, endS: Double, rmsDb: Double, spectralCentroidHz: Double
            let mfcc: [Double], f0Mean: Double?, voicedFrames: Int
        }
        let sampleRate: Double
        let segments: [Seg]
    }

    func testMatchesLibrosaOracle() throws {
        let data = try Data(contentsOf: TestSignals.fixtureURL("cat1_oracle.json"))
        let oracle = try JSONDecoder().decode(Oracle.self, from: data)
        let buffer = try AudioLoader.load(TestSignals.fixtureURL("cat1_16k.wav"))
        var voicingDisagreements = 0
        for o in oracle.segments {
            let f = FeatureExtractor.features(buffer, segment: Segment(startS: o.startS, endS: o.endS))
            let tag = "segment at \(o.startS)s"
            XCTAssertEqual(f.rmsDb, o.rmsDb, accuracy: 1.0, tag)
            XCTAssertEqual(f.spectralCentroidHz, o.spectralCentroidHz, accuracy: 0.10 * o.spectralCentroidHz, tag)
            XCTAssertEqual(f.mfcc[0], o.mfcc[0], accuracy: 0.10 * abs(o.mfcc[0]) + 1.0, tag)
            for i in 1..<13 {
                XCTAssertEqual(f.mfcc[i], o.mfcc[i], accuracy: 2.5, "\(tag) mfcc\(i)")
            }

            // The oracle's f0 is sparse: 7 of 12 segments are unvoiced in pyin, and two more sit at the
            // pyin floor with only 5 voiced frames. Compare f0 values only where pyin was confident
            // (>= 8 voiced frames and a mean above the floor); elsewhere check voicing agreement only.
            let oracleConfident = o.voicedFrames >= 8
            if oracleConfident, let ob = o.f0Mean, ob >= 100 {
                if let a = f.f0Mean {
                    XCTAssertEqual(a, ob, accuracy: 0.15 * ob, "\(tag) f0Mean")
                } else {
                    voicingDisagreements += 1
                }
            } else if o.f0Mean == nil, f.f0Mean != nil {
                voicingDisagreements += 1
            } else if oracleConfident, f.f0Mean == nil {
                voicingDisagreements += 1
            }
        }
        XCTAssertLessThanOrEqual(voicingDisagreements, 4, "YIN vs pyin voicing disagreements")
    }
}
