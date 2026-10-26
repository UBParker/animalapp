import SwiftData
import SwiftUI

@main
struct AnimalTrackerApp: App {
    @StateObject private var store: AppStoreLifecycle
    @StateObject private var auth = AuthService()

    init() {
        // Never fatalError at launch: an unopenable store must still give the user a working app.
        let opened = PersistenceController.makeContainerWithRecovery()
        Seeds.runAll(context: opened.container.mainContext)
        _store = StateObject(wrappedValue: AppStoreLifecycle(container: opened.container,
                                                             recovered: opened.recovered))
    }

    var body: some Scene {
        WindowGroup {
            // There is deliberately no `.task` here. Every piece of auth wiring lives in
            // `RootView`'s own `.task`, immediately before `restoreSession()`, so nothing depends
            // on the order SwiftUI happens to run a parent's task body against a child's.
            RootView()
                .environmentObject(auth)
                .environmentObject(store)
                .modelContainer(store.container)
        }
    }
}

/// Store seeds, run on every launch. Each one must be idempotent: a second run on a store that
/// already holds its rows has to change nothing. Later plans append their seed functions to `all`.
enum Seeds {
    static let all: [(ModelContext) -> Void] = [
        VoiceTagSeed.run,
    ]

    static func runAll(context: ModelContext) {
        for seed in all { seed(context) }
    }
}
