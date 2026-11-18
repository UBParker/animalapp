import Foundation

/// Spreadsheet views of the voice data: one row per recording, one row per vocalization. Rows
/// name the animal rather than its id, since these are for reading, not re-import.
enum VoiceCSVExporter {
    static let mfccCount = 13

    static let recordingsHeader = [
        "animal", "timestamp_iso8601", "duration_s", "audio_filename", "status", "activity", "meaning",
        "confidence", "note",
    ]

    static let vocalizationsHeader = [
        "animal", "recording_id", "start_s", "end_s", "f0_mean", "f0_min", "f0_max", "f0_slope",
        "voiced_fraction", "rms_db", "spectral_centroid_hz",
    ] + (0..<mfccCount).map { "mfcc\($0)" } + ["activity", "meaning", "confidence", "overridden"]

    static func recordings(_ bundle: ExportBundle) -> String {
        let names = animalNames(bundle)
        let rows = bundle.voiceRecordings.map { r in
            [
                r.animalId.flatMap { names[$0] } ?? "", r.recordedAt, ExportFormatters.decimal(r.durationS),
                r.audioFilename, r.status, r.activityTag ?? "", r.meaningTag ?? "",
                ExportFormatters.integer(r.userConfidence), r.note,
            ]
        }
        return CSVWriter.document(header: recordingsHeader, rows: rows)
    }

    static func vocalizations(_ bundle: ExportBundle) -> String {
        let names = animalNames(bundle)
        var animalByRecording: [String: String] = [:]
        for r in bundle.voiceRecordings {
            if let animalId = r.animalId, let name = names[animalId] { animalByRecording[r.id] = name }
        }
        let d = ExportFormatters.decimal
        let rows = bundle.vocalizations.map { v in
            let mfcc = (0..<mfccCount).map { $0 < v.mfcc.count ? d(v.mfcc[$0]) : "" }
            return [
                v.recordingId.flatMap { animalByRecording[$0] } ?? "", v.recordingId ?? "", d(v.startS), d(v.endS),
                d(v.f0Mean), d(v.f0Min), d(v.f0Max), d(v.f0Slope), d(v.voicedFraction), d(v.rmsDb),
                d(v.spectralCentroidHz),
            ] + mfcc + [
                v.activityTag ?? "", v.meaningTag ?? "", ExportFormatters.integer(v.userConfidence),
                ExportFormatters.flag(v.overridden),
            ]
        }
        return CSVWriter.document(header: vocalizationsHeader, rows: rows)
    }

    private static func animalNames(_ bundle: ExportBundle) -> [String: String] {
        Dictionary(bundle.animals.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }
}
