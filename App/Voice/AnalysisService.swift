import AnimalVoiceAudio
import Foundation
import SwiftData

enum AnalysisService {
    struct Result {
        var durationS: Double
        var events: [(segment: Segment, features: VocalFeatures)]
    }

    enum AnalysisError: Error, LocalizedError {
        case missingAudio(String)
        var errorDescription: String? {
            switch self { case .missingAudio(let name): return "Audio file missing: \(name)" }
        }
    }

    /// CPU-only decode, segment, and feature extraction. Safe to call off the main actor.
    nonisolated static func analyzeFile(at url: URL, segmenter: SegmenterConfig = .init()) throws -> Result {
        let buffer = try AudioLoader.load(url)
        return Result(durationS: buffer.durationS, events: FeatureExtractor.analyze(buffer, segmenter: segmenter))
    }

    /// Replaces the recording's vocalizations with the result and re-applies recording-level tags.
    @MainActor
    static func apply(_ result: Result, to recording: VoiceRecording, context: ModelContext) throws {
        for old in recording.vocalizations ?? [] { context.delete(old) }
        for event in result.events {
            let v = Vocalization(segment: event.segment, features: event.features)
            v.recording = recording
            context.insert(v)
        }
        recording.durationS = result.durationS
        recording.status = result.events.isEmpty ? .noSounds : .analyzed
        recording.errorMessage = nil
        TagPropagation.apply(to: recording)
        try context.save()
    }

    /// Full pipeline for a stored recording: analyze its file off the main actor, then apply on it.
    @MainActor
    static func analyze(recording: VoiceRecording, mediaStore: MediaStore, context: ModelContext,
                        segmenter: SegmenterConfig = .init()) async {
        let filename = recording.audioFilename
        guard mediaStore.exists(filename) else {
            recording.status = .failed
            recording.errorMessage = AnalysisError.missingAudio(filename).localizedDescription
            try? context.save()
            return
        }
        let url = mediaStore.url(for: filename)
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try analyzeFile(at: url, segmenter: segmenter)
            }.value
            try apply(result, to: recording, context: context)
        } catch {
            recording.status = .failed
            recording.errorMessage = error.localizedDescription
            try? context.save()
        }
    }
}
