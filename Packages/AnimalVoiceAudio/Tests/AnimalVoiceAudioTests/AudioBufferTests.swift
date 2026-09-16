import XCTest
@testable import AnimalVoiceAudio

final class AudioBufferTests: XCTestCase {
    func testDurationAndSlice() {
        let b = AudioBuffer(samples: Array(repeating: 0, count: 16_000), sampleRate: 16_000)
        XCTAssertEqual(b.durationS, 1.0, accuracy: 1e-9)
        XCTAssertEqual(b.slice(startS: 0.25, endS: 0.5).count, 4_000)
        XCTAssertEqual(b.slice(startS: 0.9, endS: 2.0).count, 1_600)
        XCTAssertEqual(b.slice(startS: 0.5, endS: 0.25).count, 0)
    }
}
