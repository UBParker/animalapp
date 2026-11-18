import Foundation
import SwiftData

/// Reads the store into an `ExportBundle`. The only part of the export that touches SwiftData.
/// Archived animals are included: an export is a backup, not a view. Every array is ordered by
/// `createdAt`, then id string, so two exports of the same store produce the same JSON.
enum ExportBundleBuilder {
    @MainActor
    static func build(context: ModelContext) throws -> ExportBundle {
        let ts = ExportFormatters.timestamp
        var bundle = ExportBundle()
        bundle.animals = try fetchSorted(Animal.self, context, \.createdAt, \.id).map {
            AnimalExport(id: $0.id.uuidString, createdAt: ts($0.createdAt), name: $0.name, species: $0.species,
                         colorHex: $0.colorHex, photoFilename: $0.photoFilename,
                         photoThumbnailFilename: $0.photoThumbnailFilename, tracksOutdoorTime: $0.tracksOutdoorTime,
                         sortOrder: $0.sortOrder, isArchived: $0.isArchived, note: $0.note)
        }
        bundle.voiceTags = try fetchSorted(VoiceTag.self, context, \.createdAt, \.id).map {
            VoiceTagExport(id: $0.id.uuidString, createdAt: ts($0.createdAt), kind: $0.kindRaw, name: $0.name,
                           isBuiltIn: $0.isBuiltIn, sortOrder: $0.sortOrder, updatedAt: ts($0.updatedAt))
        }
        bundle.voiceRecordings = try fetchSorted(VoiceRecording.self, context, \.createdAt, \.id).map {
            VoiceRecordingExport(id: $0.id.uuidString, createdAt: ts($0.createdAt), animalId: $0.animal?.id.uuidString,
                                 recordedAt: ts($0.recordedAt), durationS: $0.durationS, audioFilename: $0.audioFilename,
                                 status: $0.statusRaw, errorMessage: $0.errorMessage, note: $0.note,
                                 activityTag: $0.activityTag, meaningTag: $0.meaningTag,
                                 userConfidence: $0.userConfidence, editedAt: ExportFormatters.optionalTimestamp($0.editedAt),
                                 updatedAt: ts($0.updatedAt))
        }
        bundle.vocalizations = try fetchSorted(Vocalization.self, context, \.createdAt, \.id).map {
            VocalizationExport(id: $0.id.uuidString, createdAt: ts($0.createdAt), recordingId: $0.recording?.id.uuidString,
                               startS: $0.startS, endS: $0.endS, f0Mean: $0.f0Mean, f0Min: $0.f0Min, f0Max: $0.f0Max,
                               f0Slope: $0.f0Slope, voicedFraction: $0.voicedFraction, rmsDb: $0.rmsDb,
                               spectralCentroidHz: $0.spectralCentroidHz, mfcc: $0.mfcc, activityTag: $0.activityTag,
                               meaningTag: $0.meaningTag, userConfidence: $0.userConfidence, overridden: $0.overridden,
                               updatedAt: ts($0.updatedAt))
        }
        return bundle
    }

    @MainActor
    private static func fetchSorted<T: PersistentModel>(
        _ type: T.Type, _ context: ModelContext, _ createdAt: KeyPath<T, Date>, _ id: KeyPath<T, UUID>
    ) throws -> [T] {
        try context.fetch(FetchDescriptor<T>()).sorted {
            let (a, b) = ($0[keyPath: createdAt], $1[keyPath: createdAt])
            return a != b ? a < b : $0[keyPath: id].uuidString < $1[keyPath: id].uuidString
        }
    }
}
