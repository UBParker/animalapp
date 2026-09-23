import CryptoKit
import Foundation
import SwiftData

enum VoiceTagSeed {
    static let activities = ["Eating", "Waiting at door", "Being petted", "Playing", "Alone",
                             "Greeting a person", "Looking out window", "At the vet", "On a walk", "Other"]
    static let meanings = ["Hungry", "Wants attention", "Wants out or in", "Greeting", "Annoyed",
                           "In pain or distress", "Content", "Alert or warning", "Unknown"]
    static let unknownMeaning = "Unknown"
    /// Retired flag from the first version of this seed. Seeding is name-idempotent and now runs on
    /// every launch, so a store created after this key was set still gets its built-in tags. The key
    /// is kept only so an old install's value has a name here.
    static let seededKey = "hasSeededVoiceTags"

    /// The RFC 4122 DNS namespace. Fixed forever: a different namespace would give every built-in
    /// tag a different id, and existing rows would no longer match the ones the seed inserts.
    private static let namespace = UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")!

    /// The stable id of a built-in tag: a version 5 (SHA-1) UUID over the namespace and
    /// "kind:name". The same built-in tag therefore carries the same id in every store, so a second
    /// seed lands on the row that is already there instead of inserting a near-duplicate.
    static func builtInID(kind: VoiceTagKind, name: String) -> UUID {
        let seed = Data(withUnsafeBytes(of: namespace.uuid) { Array($0) }) + Data("\(kind.rawValue):\(name)".utf8)
        var b = [UInt8](Insecure.SHA1.hash(data: seed).prefix(16))
        b[6] = (b[6] & 0x0F) | 0x50   // version 5
        b[8] = (b[8] & 0x3F) | 0x80   // RFC 4122 variant
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    /// Inserts the built-in tags that are not in the store yet. Returns how many were added.
    ///
    /// Identity is the deterministic id, not the name: a built-in the user renamed still has the id
    /// its original name hashes to, so it is recognised and left alone rather than re-inserted
    /// alongside the rename. The name is checked too, so a tag the user created by hand under a
    /// built-in's name is not shadowed by a second row carrying the same name.
    @discardableResult
    static func seedIfNeeded(context: ModelContext) throws -> Int {
        let existing = try context.fetch(FetchDescriptor<VoiceTag>())
        let ids = Set(existing.map(\.id))
        var added = 0
        func seed(_ names: [String], kind: VoiceTagKind) {
            let present = Set(existing.filter { $0.kind == kind }.map(\.name))
            for (i, name) in names.enumerated() {
                let id = builtInID(kind: kind, name: name)
                guard !ids.contains(id), !present.contains(name) else { continue }
                context.insert(VoiceTag(id: id, kind: kind, name: name, isBuiltIn: true, sortOrder: i))
                added += 1
            }
        }
        seed(activities, kind: .activity)
        seed(meanings, kind: .meaning)
        if added > 0 { try context.save() }
        return added
    }

    /// App-launch entry. Runs on every launch rather than once per install: matching is by the
    /// deterministic id or the name, so a store that already has the tags gains nothing, and a
    /// store created later still gets them.
    static func run(_ context: ModelContext) {
        do {
            try seedIfNeeded(context: context)
        } catch {
            NSLog("Voice tag seeding failed: %@", String(describing: error))
        }
    }
}
