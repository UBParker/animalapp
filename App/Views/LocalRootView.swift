import SwiftUI

/// Which root the app shows. Kept separate from the view so the choice is unit-testable.
enum AppRoot: Equatable {
    /// No sign-in screen and no sync: `LocalRootView`.
    case localOnly
    /// The sign-in gate: `RootView`.
    case authGated

    static func choose(localOnly: Bool) -> AppRoot {
        localOnly ? .localOnly : .authGated
    }
}

/// The root of a local-only build. It goes straight to the tabs: there is no sign-in screen, no
/// offline banner (being offline is the whole point of this mode, not a warning), and nothing here
/// touches `AuthService`.
struct LocalRootView: View {
    @EnvironmentObject private var store: AppStoreLifecycle

    var body: some View {
        // A real container owns the `.task`, so the task's identity never changes. Only the content
        // inside carries the generation identity, as in `RootView`: putting `.id` on the view that
        // owns the `.task` would re-run it after every store generation.
        ZStack {
            VStack(spacing: 0) {
                if store.recovered {
                    RecoveredStoreBanner()
                }
                RootTabView()
            }
            .id(store.generation)
        }
        .task {
            // A no-op today: nothing in a local-only build assigns `store.sync`, so there is no
            // coordinator to update. Kept so that if one is ever assigned it starts in the offline
            // state with no client, and nothing leaves the device.
            store.configureSync(for: .offline, client: nil)
        }
    }
}
