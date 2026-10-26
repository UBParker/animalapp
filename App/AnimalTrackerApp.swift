import SwiftData
import SwiftUI

@main
struct AnimalTrackerApp: App {
    @StateObject private var store: AppStoreLifecycle
    @StateObject private var auth = AuthService()

    init() {
        // A5. One expression for the path, passed to both calls. The app used to open the store
        // with `url: nil`, letting SwiftData choose, while `AppStoreLifecycle` destroyed a derived
        // `PersistenceController.storeURL`: two expressions assumed to be one path, load-bearing
        // for every destructive path. If they ever differed the wipe would unlink nothing, the
        // reopen would return the untouched store, and one person's records would be adopted into
        // the next person's account on every sign-out, with no filesystem error anywhere.
        // `ContainerResetTests.testTheDefaultStoreConfigurationIsTheSamePathTheWipeDestroys` pins
        // that they do match today; this makes it true by construction rather than by agreement.
        let storeURL = PersistenceController.storeURL
        // Never fatalError at launch: an unopenable store must still give the user a working app.
        let opened = PersistenceController.makeContainerWithRecovery(url: storeURL)
        Seeds.runAll(context: opened.container.mainContext)
        _store = StateObject(wrappedValue: AppStoreLifecycle(container: opened.container,
                                                             recovered: opened.recovered,
                                                             storeURL: storeURL))
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
                // One media store for the whole app, the same object the wipe removes files
                // through and the one Task 11 hands to sync. Two `FileMediaStore()` defaults
                // agreeing on a root by convention is a wipe that misses live files the moment
                // anybody injects one of them and not the other, with no compile error.
                .environment(\.mediaStore, store.mediaStore)
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
