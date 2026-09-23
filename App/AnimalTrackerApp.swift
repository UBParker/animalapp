import SwiftData
import SwiftUI

@main
struct AnimalTrackerApp: App {
    let container: ModelContainer
    /// True when the store could not be opened at all and this launch runs on a temporary store.
    let recovered: Bool

    init() {
        // Never fatalError at launch: an unopenable store must still give the user a working app.
        (container, recovered) = PersistenceController.makeContainerWithRecovery()
        Seeds.runAll(context: container.mainContext)
    }

    var body: some Scene {
        WindowGroup {
            VStack(spacing: 0) {
                if recovered {
                    Text("The data store could not be opened. Running with a temporary store; export your data if this persists.")
                        .font(.footnote)
                        .padding(8)
                        .frame(maxWidth: .infinity)
                        .background(.yellow)
                }
                RootTabView()
            }
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
