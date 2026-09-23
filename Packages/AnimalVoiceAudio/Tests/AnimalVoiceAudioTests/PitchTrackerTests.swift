import XCTest
@testable import AnimalVoiceAudio

final class PitchTrackerTests: XCTestCase {
    private func assertTracks(_ hz: Double, file: StaticString = #filePath, line: UInt = #line) {
        let frames = PitchTracker.track(TestSignals.sine(frequency: hz, seconds: 0.5), sampleRate: 16_000)
        XCTAssertEqual(frames.count, 24, file: file, line: line) // 1 + (8000 - 640) / 320
        let voiced = frames.compactMap(\.f0Hz)
        XCTAssertGreaterThanOrEqual(voiced.count, 22, "most frames voiced at \(hz) Hz", file: file, line: line)
        let mean = voiced.reduce(0, +) / Double(voiced.count)
        XCTAssertEqual(mean, hz, accuracy: hz * 0.02, file: file, line: line)
    }

    func testTracksPureTones() {
        assertTracks(220)
        assertTracks(440)
        assertTracks(880)
    }

    func testSilenceIsUnvoiced() {
        let frames = PitchTracker.track(TestSignals.silence(seconds: 0.5), sampleRate: 16_000)
        XCTAssertEqual(frames.count, 24)
        XCTAssertTrue(frames.allSatisfy { $0.f0Hz == nil })
    }

    func testTooShortInputGivesNoFrames() {
        XCTAssertEqual(PitchTracker.track(TestSignals.sine(frequency: 440, seconds: 0.01), sampleRate: 16_000).count, 0)
    }

    func testFrameTimesAdvanceByHop() {
        let frames = PitchTracker.track(TestSignals.sine(frequency: 440, seconds: 0.2), sampleRate: 16_000)
        XCTAssertEqual(frames[1].timeS - frames[0].timeS, 0.02, accuracy: 1e-9)
    }
}
