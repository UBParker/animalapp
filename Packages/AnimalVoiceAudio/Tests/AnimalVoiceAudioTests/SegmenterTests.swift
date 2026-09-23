import XCTest
@testable import AnimalVoiceAudio

final class SegmenterTests: XCTestCase {
    private func burstsBuffer() -> AudioBuffer {
        // 0.5 s silence, 0.3 s tone, 0.5 s silence, 0.05 s gap-bridged pair (0.2 s tone, 0.05 s gap, 0.2 s tone), 0.5 s silence, 0.03 s blip (too short)
        var s: [Float] = []
        s += TestSignals.silence(seconds: 0.5)
        s += TestSignals.sine(frequency: 500, seconds: 0.3)
        s += TestSignals.silence(seconds: 0.5)
        s += TestSignals.sine(frequency: 500, seconds: 0.2)
        s += TestSignals.silence(seconds: 0.05)
        s += TestSignals.sine(frequency: 500, seconds: 0.2)
        s += TestSignals.silence(seconds: 0.5)
        s += TestSignals.sine(frequency: 500, seconds: 0.03)
        s += TestSignals.silence(seconds: 0.5)
        return AudioBuffer(samples: s, sampleRate: 16_000)
    }

    func testFindsBurstsBridgesGapsDropsShortRuns() {
        let segs = Segmenter.segment(burstsBuffer())
        XCTAssertEqual(segs.count, 2, "\(segs)")
        XCTAssertEqual(segs[0].startS, 0.5, accuracy: 0.05)
        XCTAssertEqual(segs[0].endS, 0.8, accuracy: 0.06)
        XCTAssertEqual(segs[1].startS, 1.3, accuracy: 0.05)
        XCTAssertEqual(segs[1].endS, 1.75, accuracy: 0.06)
    }

    func testSilenceYieldsNothing() {
        let segs = Segmenter.segment(AudioBuffer(samples: TestSignals.silence(seconds: 2), sampleRate: 16_000))
        XCTAssertEqual(segs, [])
    }

    func testQuietSignalBelowFloorYieldsNothing() {
        // -60 dBFS tone is below the -50 dBFS floor even though it is the loudest thing present
        let quiet = TestSignals.sine(frequency: 500, seconds: 1, amplitude: 0.001)
        XCTAssertEqual(Segmenter.segment(AudioBuffer(samples: quiet, sampleRate: 16_000)), [])
    }

    func testFrameRmsDbShape() {
        let b = AudioBuffer(samples: TestSignals.sine(frequency: 500, seconds: 1.0, amplitude: 1.0), sampleRate: 16_000)
        let db = Segmenter.frameRmsDb(b)
        XCTAssertEqual(db.count, 49) // 1 + (16000 - 640) / 320
        XCTAssertEqual(db[10], -3.01, accuracy: 0.2) // full-scale sine rms = 0.707
    }

    func testSampleRecordingSegmentCount() throws {
        let b = try AudioLoader.load(TestSignals.fixtureURL("cat1_16k.wav"))
        let segs = Segmenter.segment(b)
        print("cat1 segments:", segs.map { String(format: "%.2f-%.2f", $0.startS, $0.endS) })
        XCTAssertTrue((10...14).contains(segs.count), "got \(segs.count) segments")
        XCTAssertTrue(segs.contains { abs($0.startS - 36.68) < 0.05 }, "expected the loud meow near 36.7 s")
        XCTAssertTrue(segs.contains { abs($0.startS - 60.34) < 0.05 }, "expected the loud meow near 60.3 s")
    }
}
