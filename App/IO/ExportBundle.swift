import Foundation

/// How exported values are written, shared by the JSON and the CSV files.
enum ExportFormatters {
    /// ISO 8601 with the local UTC offset and no fractional seconds, e.g. 2026-11-17T09:30:00-05:00.
    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    static func optionalTimestamp(_ date: Date?) -> String? { date.map(timestamp) }

    /// `String(Double)`, or an empty field for nil.
    static func decimal(_ value: Double?) -> String { value.map { String($0) } ?? "" }

    static func integer(_ value: Int?) -> String { value.map { String($0) } ?? "" }

    static func flag(_ value: Bool) -> String { value ? "true" : "false" }
}

/// The whole export as one JSON document. Every top-level key is always written, so a reader can
/// rely on the shape even when a section has no rows. Relationships are ids, timestamps are
/// `ExportFormatters.timestamp` strings.
struct ExportBundle: Codable, Equatable {
    static let currentVersion = 4

    var version: Int = ExportBundle.currentVersion
    var animals: [AnimalExport] = []
    var buttons: [PendingExport] = []
    var presses: [PendingExport] = []
    var feedDays: [PendingExport] = []
    var feedings: [PendingExport] = []
    var feedItems: [PendingExport] = []
    var poopTags: [PendingExport] = []
    var poopObservations: [PendingExport] = []
    var healthCheckIns: [PendingExport] = []
    var oralCheckIns: [PendingExport] = []
    var checkInTurns: [PendingExport] = []
    var voiceTags: [VoiceTagExport] = []
    var voiceRecordings: [VoiceRecordingExport] = []
    var vocalizations: [VocalizationExport] = []
}

/// Placeholder for a section this export does not fill yet, so the key is present and always an
/// empty array. Plan G replaces each use with the real export type for that section.
struct PendingExport: Codable, Equatable {}

struct AnimalExport: Codable, Equatable {
    var id: String = ""
    var createdAt: String = ""
    var name: String = ""
    var species: String = ""
    var colorHex: String = ""
    var photoFilename: String?
    var photoThumbnailFilename: String?
    var tracksOutdoorTime: Bool = false
    var sortOrder: Int = 0
    var isArchived: Bool = false
    var note: String?
}

struct VoiceTagExport: Codable, Equatable {
    var id: String = ""
    var createdAt: String = ""
    var kind: String = ""
    var name: String = ""
    var isBuiltIn: Bool = false
    var sortOrder: Int = 0
    var updatedAt: String?
}

struct VoiceRecordingExport: Codable, Equatable {
    var id: String = ""
    var createdAt: String = ""
    var animalId: String?
    var recordedAt: String = ""
    var durationS: Double = 0
    var audioFilename: String = ""
    var status: String = ""
    var errorMessage: String?
    var note: String = ""
    var activityTag: String?
    var meaningTag: String?
    var userConfidence: Int?
    var editedAt: String?
    var updatedAt: String?
}

struct VocalizationExport: Codable, Equatable {
    var id: String = ""
    var createdAt: String = ""
    var recordingId: String?
    var startS: Double = 0
    var endS: Double = 0
    var f0Mean: Double?
    var f0Min: Double?
    var f0Max: Double?
    var f0Slope: Double?
    var voicedFraction: Double = 0
    var rmsDb: Double = -160
    var spectralCentroidHz: Double = 0
    var mfcc: [Double] = []
    var activityTag: String?
    var meaningTag: String?
    var userConfidence: Int?
    var overridden: Bool = false
    var updatedAt: String?
}
