import AVFoundation
import Foundation

enum TestSignals {
    static func sine(frequency: Double, seconds: Double, sampleRate: Double = 16_000, amplitude: Float = 0.5) -> [Float] {
        let n = Int(seconds * sampleRate)
        return (0..<n).map { i in amplitude * Float(sin(2 * .pi * frequency * Double(i) / sampleRate)) }
    }

    static func silence(seconds: Double, sampleRate: Double = 16_000) -> [Float] {
        Array(repeating: 0, count: Int(seconds * sampleRate))
    }

    /// Writes mono samples to a 16-bit PCM WAV, duplicating the channel if `channels` > 1.
    /// Pass `rightSamples` with `channels == 2` to give the right channel a distinct signal
    /// (must have the same count as `samples`).
    static func writeWav(_ samples: [Float], sampleRate: Double, channels: Int = 1, rightSamples: [Float]? = nil) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("animalvoice-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: AVAudioChannelCount(channels), interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for c in 0..<channels {
            let channelSamples = (c == 1 && channels == 2) ? (rightSamples ?? samples) : samples
            precondition(channelSamples.count == samples.count, "rightSamples must match samples count")
            channelSamples.withUnsafeBufferPointer { src in
                buffer.floatChannelData![c].update(from: src.baseAddress!, count: channelSamples.count)
            }
        }
        try file.write(from: buffer)
        return url
    }

    static func fixtureURL(_ name: String) -> URL {
        Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
    }
}
