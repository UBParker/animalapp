import AVFoundation
import Foundation

public enum AudioLoaderError: Error {
    case allocationFailed
    case conversionFailed(String)
}

public enum AudioLoader {
    public static let targetSampleRate: Double = 16_000

    /// Decodes any AVFoundation-readable file (m4a, wav, caf, mp3) to mono Float32 at 16 kHz.
    public static func load(_ url: URL) throws -> AudioBuffer {
        let file = try AVAudioFile(forReading: url)
        let srcFormat = file.processingFormat
        let frameCount = AVAudioFrameCount(max(file.length, 1))
        guard let src = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount) else {
            throw AudioLoaderError.allocationFailed
        }
        try file.read(into: src)

        guard let dstFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetSampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: srcFormat, to: dstFormat) else {
            throw AudioLoaderError.conversionFailed("cannot build converter from \(srcFormat)")
        }
        let ratio = targetSampleRate / srcFormat.sampleRate
        let dstCapacity = AVAudioFrameCount(Double(src.frameLength) * ratio) + 4096
        guard let dst = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: dstCapacity) else {
            throw AudioLoaderError.allocationFailed
        }

        var delivered = false
        var conversionError: NSError?
        let status = converter.convert(to: dst, error: &conversionError) { _, outStatus in
            if delivered {
                outStatus.pointee = .endOfStream
                return nil
            }
            delivered = true
            outStatus.pointee = .haveData
            return src
        }
        if status == .error {
            throw AudioLoaderError.conversionFailed(conversionError?.localizedDescription ?? "unknown")
        }
        let count = Int(dst.frameLength)
        guard let channel = dst.floatChannelData?[0] else { throw AudioLoaderError.allocationFailed }
        return AudioBuffer(samples: Array(UnsafeBufferPointer(start: channel, count: count)), sampleRate: targetSampleRate)
    }
}
