import Foundation
import SwiftData

/// An animal can be deleted only when it has no records in any domain; otherwise archive it.
enum AnimalDeletionPolicy {
    /// Record counts by domain name. Each domain plan adds one entry here.
    static func recordCounts(for animal: Animal, context: ModelContext) throws -> [String: Int] {
        let counts: [String: Int] = [:]
        _ = animal
        _ = context
        return counts
    }

    static func canDelete(_ animal: Animal, context: ModelContext) throws -> Bool {
        try recordCounts(for: animal, context: context).values.allSatisfy { $0 == 0 }
    }

    /// "3 presses, 2 feed days" for the blocking alert.
    static func summary(_ counts: [String: Int]) -> String {
        counts.filter { $0.value > 0 }.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", ")
    }
}
