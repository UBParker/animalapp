import AVFoundation
import Foundation

enum TestAudioFile {
    /// 0.3 s silence, 0.4 s 600 Hz tone, 0.3 s silence, encoded as mono AAC at 16 kHz in an .m4a.
    static func toneBurstM4A() throws -> URL {
        let sr = 16_000.0
        var samples = [Float](repeating: 0, count: 4_800)
        samples += (0..<6_400).map { 0.5 * Float(sin(2 * Double.pi * 600 * Double($0) / sr)) }
        samples += [Float](repeating: 0, count: 4_800)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        try write(samples, sampleRate: sr, to: url)
        return url
    }

    private static func write(_ samples: [Float], sampleRate: Double, to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try file.write(from: buffer)
        // `file` closes when this function returns.
    }
}
