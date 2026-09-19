import SwiftData
@testable import AnimalTracker

enum TestSupport {
    /// A ModelContext does not keep its ModelContainer alive, so a test that holds only
    /// `TestSupport.container().mainContext` traps inside SwiftData once the container
    /// deallocates. Hold every container made for a test for the life of the test process.
    private static var retained: [ModelContainer] = []

    static func container() throws -> ModelContainer {
        let container = try PersistenceController.makeContainer(inMemory: true)
        retained.append(container)
        return container
    }
}
