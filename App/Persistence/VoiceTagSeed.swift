import Foundation
import SwiftData

enum VoiceTagSeed {
    static let activities = ["Eating", "Waiting at door", "Being petted", "Playing", "Alone",
                             "Greeting a person", "Looking out window", "At the vet", "On a walk", "Other"]
    static let meanings = ["Hungry", "Wants attention", "Wants out or in", "Greeting", "Annoyed",
                           "In pain or distress", "Content", "Alert or warning", "Unknown"]
    static let unknownMeaning = "Unknown"
    static let seededKey = "hasSeededVoiceTags"

    /// Inserts any built-in tag whose name is missing. Returns how many were added.
    @discardableResult
    static func seedIfNeeded(context: ModelContext) throws -> Int {
        let existing = try context.fetch(FetchDescriptor<VoiceTag>())
        var added = 0
        func seed(_ names: [String], kind: VoiceTagKind) {
            let present = Set(existing.filter { $0.kind == kind }.map(\.name))
            for (i, name) in names.enumerated() where !present.contains(name) {
                context.insert(VoiceTag(kind: kind, name: name, isBuiltIn: true, sortOrder: i))
                added += 1
            }
        }
        seed(activities, kind: .activity)
        seed(meanings, kind: .meaning)
        if added > 0 { try context.save() }
        return added
    }

    /// App-launch entry: runs once per install, guarded by UserDefaults.
    static func run(_ context: ModelContext) {
        guard !UserDefaults.standard.bool(forKey: seededKey) else { return }
        do {
            try seedIfNeeded(context: context)
            UserDefaults.standard.set(true, forKey: seededKey)
        } catch {
            NSLog("Voice tag seeding failed: %@", String(describing: error))
        }
    }
}
