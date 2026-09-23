import Foundation
import SwiftData

@Model
final class VoiceRecording {
    @Attribute(.unique) var id: UUID = UUID()
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var recordedAt: Date = Date()
    var durationS: Double = 0
    /// "<uuid>-audio.m4a", relative to Documents/Media/.
    var audioFilename: String = ""
    var statusRaw: String = VoiceStatus.recorded.rawValue
    var errorMessage: String?
    var note: String = ""
    var activityTag: String?
    var meaningTag: String?
    /// 1 guess, 2 fairly sure, 3 certain
    var userConfidence: Int?
    var editedAt: Date?
    var animal: Animal?
    @Relationship(deleteRule: .cascade, inverse: \Vocalization.recording) var vocalizations: [Vocalization]?

    init(audioFilename: String, durationS: Double, recordedAt: Date = Date(), animal: Animal? = nil) {
        self.audioFilename = audioFilename
        self.durationS = durationS
        self.recordedAt = recordedAt
        self.animal = animal
    }

    var status: VoiceStatus {
        get { VoiceStatus(rawValue: statusRaw) ?? .recorded }
        set { statusRaw = newValue.rawValue }
    }

    var sortedVocalizations: [Vocalization] {
        (vocalizations ?? []).sorted { $0.startS < $1.startS }
    }
}
