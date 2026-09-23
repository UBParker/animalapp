import Foundation
import SwiftData

/// Deleting the audio file first leaves a recording that still points at it if the save then fails,
/// which reads as "audio file missing" forever. The file goes last, after the row's delete is on
/// disk, so a failed save leaves the recording intact and still playable.
enum RecordingDeleter {
    @MainActor
    static func delete(_ recording: VoiceRecording, context: ModelContext, mediaStore: MediaStore) throws {
        // Captured up front: the filename is unreadable off a model once it is deleted.
        let filename = recording.audioFilename
        context.delete(recording)
        try context.save()
        mediaStore.delete(filename)
    }
}
