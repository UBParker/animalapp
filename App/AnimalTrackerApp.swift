import SwiftData
import SwiftUI

@main
struct AnimalTrackerApp: App {
    let container: ModelContainer

    init() {
        do {
            container = try PersistenceController.makeContainer()
        } catch {
            fatalError("Cannot open the data store: \(error)")
        }
        Seeds.runAll(context: container.mainContext)
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
        }
        .modelContainer(container)
    }
}

/// One-time seeds. Later plans append their seed functions to `all`.
enum Seeds {
    static let all: [(ModelContext) -> Void] = []

    static func runAll(context: ModelContext) {
        for seed in all { seed(context) }
    }
}
