import SwiftUI

/// What the root shows. Kept separate from the view so the gating rule is unit-testable.
enum RootScreen: Equatable {
    case loading
    case signIn
    /// A build with no usable anon key. Never the tabs.
    case blocked
    case main(showsOfflineBanner: Bool)
}

enum RootGate {
    static func screen(for state: AuthState) -> RootScreen {
        switch state {
        case .unknown:
            return .loading
        case .signedOut:
            return .signIn
        case .signedIn:
            return .main(showsOfflineBanner: false)
        case .offline:
            return .main(showsOfflineBanner: true)
        case .misconfigured:
            return .blocked
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var store: AppStoreLifecycle

    var body: some View {
        Group {
            switch RootGate.screen(for: auth.state) {
            case .loading:
                ProgressView("Loading")
            case .signIn:
                SignInView()
            case .blocked:
                MisconfiguredView()
            case .main(let showsOfflineBanner):
                VStack(spacing: 0) {
                    if store.recovered {
                        Text("The data store could not be opened. Running with a temporary store; export your data if this persists.")
                            .font(.footnote)
                            .padding(8)
                            .frame(maxWidth: .infinity)
                            .background(.yellow)
                    }
                    if showsOfflineBanner { OfflineBanner() }
                    RootTabView()
                }
                // Only the tab content carries the generation identity. Putting it on RootView
                // itself would re-run the `.task` below after every wipe.
                .id(store.generation)
            }
        }
        .task {
            // Everything the session restore depends on is wired here, in this order, one line
            // before the restore itself. v2 set `auth.lifecycle` in the App-level `.task` and
            // called `restoreSession()` here, betting that a parent's task body runs before its
            // child's. SwiftUI does not promise that, and losing the bet means `restoreSession()`
            // decides store ownership with no lifecycle: it cannot ask whether the store is empty,
            // and it cannot cancel or wipe. There is no ordering left to get wrong if the wiring
            // and the restore are statements in one function.
            auth.lifecycle = store
            // The push an unattended sign-out attempts before anything is destroyed. `AuthService`
            // takes it as a closure rather than calling `SyncCoordinating` itself, so that
            // protocol stays declared once, here in Task 5. Nil sync means nothing to push, which
            // is `true`. Weak, so this closure cannot keep the lifecycle alive past the scene.
            auth.finalPushBeforeSignOut = { [weak store] timeout in
                await store?.sync?.pushBeforeSignOut(timeout: timeout) ?? true
            }
            auth.startWatchingAppleCredential()
            await auth.restoreSession()
        }
    }
}

struct OfflineBanner: View {
    var body: some View {
        Text("Offline. Records stay on this phone and are not backed up.")
            .font(.footnote)
            .frame(maxWidth: .infinity)
            .padding(8)
            .background(Color.orange.opacity(0.25))
            .accessibilityIdentifier("offlineBanner")
    }
}

/// The fail-closed screen. A release build that shipped without an anon key shows this and nothing
/// else: no tabs, no offline mode, no way to write records that could never be backed up.
struct MisconfiguredView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.orange)
            Text("This build is not configured")
                .font(.title2.bold())
            Text("AnimalTracker was built without its Supabase key, so it cannot sign in or back anything up. Install a build from the App Store or from TestFlight.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .accessibilityIdentifier("misconfiguredScreen")
    }
}
