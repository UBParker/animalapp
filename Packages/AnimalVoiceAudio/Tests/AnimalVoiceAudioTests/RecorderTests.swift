import AVFoundation
import XCTest
@testable import AnimalVoiceAudio

final class RecorderTests: XCTestCase {
    @MainActor
    func testInitialStateAndStopBeforeStart() {
        let r = Recorder()
        XCTAssertFalse(r.isRecording)
        XCTAssertEqual(r.levelDb, -160)
        XCTAssertNil(r.stop())
    }

    func testSettingsAreAacMono() {
        XCTAssertEqual(Recorder.settings[AVFormatIDKey] as? UInt32, kAudioFormatMPEG4AAC)
        XCTAssertEqual(Recorder.settings[AVNumberOfChannelsKey] as? Int, 1)
    }
}
