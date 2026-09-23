import XCTest
@testable import AnimalVoiceAudio

final class AudioLoaderTests: XCTestCase {
    func testResamplesStereo48kToMono16k() throws {
        let src = TestSignals.sine(frequency: 440, seconds: 1.0, sampleRate: 48_000)
        let url = try TestSignals.writeWav(src, sampleRate: 48_000, channels: 2)
        let buffer = try AudioLoader.load(url)
        XCTAssertEqual(buffer.sampleRate, 16_000)
        XCTAssertEqual(buffer.samples.count, 16_000, accuracy: 100)
        XCTAssertEqual(buffer.samples.max() ?? 0, 0.5, accuracy: 0.05)
    }

    func testLoadsM4aFixture() throws {
        let buffer = try AudioLoader.load(TestSignals.fixtureURL("cat1.m4a"))
        XCTAssertEqual(buffer.sampleRate, 16_000)
        XCTAssertEqual(buffer.durationS, 91.0, accuracy: 0.5)
        XCTAssertGreaterThan(buffer.samples.map(abs).max() ?? 0, 0.5)
    }

    func testMissingFileThrows() {
        XCTAssertThrowsError(try AudioLoader.load(URL(fileURLWithPath: "/nonexistent.wav")))
    }
}
