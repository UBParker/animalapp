import Foundation
import SwiftData

enum PersistenceController {
    /// Every @Model type in the app. Later plans append their models here.
    static let modelTypes: [any PersistentModel.Type] = [
        Animal.self,
    ]

    static var schema: Schema { Schema(modelTypes) }

    /// Local-only store. No CloudKit, by design (spec ruling 1).
    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let config = inMemory
            ? ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            : ModelConfiguration(cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [config])
    }
}
