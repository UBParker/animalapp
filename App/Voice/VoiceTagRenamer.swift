import Foundation
import SwiftData

/// Renaming a voice tag without migrating the labels already written onto recordings and sounds
/// leaves those rows pointing at a name no picker offers any more, and the model then treats the old
/// and new names as two separate meanings. This rewrites the tag and every label carrying its old
/// name in one save, so the store never holds a half-applied rename.
enum VoiceTagRenamer {
    @MainActor
    static func rename(tag: VoiceTag, to name: String, context: ModelContext) throws {
        // A model deleted out from under the row has no context; writing to it would be a write to nothing.
        guard tag.modelContext != nil else { return }
        let old: String? = tag.name
        guard old != name else { return }

        tag.name = name
        switch tag.kind {
        case .activity:
            for r in try context.fetch(FetchDescriptor<VoiceRecording>(predicate: #Predicate { $0.activityTag == old })) {
                r.activityTag = name
            }
            for v in try context.fetch(FetchDescriptor<Vocalization>(predicate: #Predicate { $0.activityTag == old })) {
                v.activityTag = name
            }
        case .meaning:
            for r in try context.fetch(FetchDescriptor<VoiceRecording>(predicate: #Predicate { $0.meaningTag == old })) {
                r.meaningTag = name
            }
            for v in try context.fetch(FetchDescriptor<Vocalization>(predicate: #Predicate { $0.meaningTag == old })) {
                v.meaningTag = name
            }
        }
        try context.save()
    }
}
