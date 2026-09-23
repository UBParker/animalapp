import AVFoundation
import Foundation

public enum RecorderError: Error {
    case alreadyRecording
    case sessionFailed(String)
}

/// Records mono AAC to a temporary .m4a and publishes a live level for the waveform view.
@MainActor
public final class Recorder: NSObject, ObservableObject {
    @Published public private(set) var isRecording = false
    @Published public private(set) var levelDb: Float = -160
    @Published public private(set) var elapsedS: TimeInterval = 0

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var fileURL: URL?

    public override init() { super.init() }

    public static let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 48_000.0,
        AVNumberOfChannelsKey: 1,
        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
    ]

    public static func requestPermission() async -> Bool {
        #if os(iOS)
        return await AVAudioApplication.requestRecordPermission()
        #else
        return true
        #endif
    }

    @discardableResult
    public func start() throws -> URL {
        guard !isRecording else { throw RecorderError.alreadyRecording }
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
        } catch {
            throw RecorderError.sessionFailed(error.localizedDescription)
        }
        #endif
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID().uuidString).m4a")
        let r = try AVAudioRecorder(url: url, settings: Self.settings)
        r.isMeteringEnabled = true
        guard r.record() else { throw RecorderError.sessionFailed("AVAudioRecorder.record() returned false") }
        recorder = r
        fileURL = url
        isRecording = true
        elapsedS = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        return url
    }

    private func tick() {
        guard let r = recorder, r.isRecording else { return }
        r.updateMeters()
        levelDb = r.averagePower(forChannel: 0)
        elapsedS = r.currentTime
    }

    /// Stops recording and returns the file URL, or nil if nothing was recording.
    public func stop() -> URL? {
        guard isRecording, let r = recorder else { return nil }
        r.stop()
        timer?.invalidate()
        timer = nil
        recorder = nil
        isRecording = false
        levelDb = -160
        return fileURL
    }
}
