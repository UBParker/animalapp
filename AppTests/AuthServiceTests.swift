import AuthenticationServices
import Security
import Supabase
import XCTest
@testable import AnimalTracker

// `Supabase` exports an `AuthError` of its own, so this app's one is written out in full wherever
// it appears below. Inside the app target the module's own declaration wins and no qualification
// is needed; here both modules are in scope at once.

/// Records the order AuthService drives the store through. The whole point of `StoreLifecycle` is
/// that this order is one function's business, not the emergent result of two `.onChange` handlers.
@MainActor
final class FakeStoreLifecycle: StoreLifecycle {
    enum Event: Equatable {
        case cancelSync
        case wipeStore
        case configureSync(String)
    }

    var events: [Event] = []
    var isEmpty = true

    /// Run inside `cancelSync()` and inside `wipeStore()`, before the event is recorded. They are
    /// what lets a test see the world *at the moment* a step runs rather than after the whole
    /// transition has finished, which is how the F1 ordering and the C1 ownership ordering are
    /// pinned.
    var onCancelSync: (@MainActor () async -> Void)?
    var onWipeStore: (@MainActor () async -> Void)?

    /// Captured inside `configureSync`, for C1. Asserting after `establish` returns cannot tell
    /// whether the claim was written before or after sync was configured.
    var defaultsForOwnerLookup: UserDefaults?
    var ownerAtConfigure: String??
    var stateAtConfigure: AuthState?

    /// Set to make `storeIsEmpty()` report "I could not tell" instead of a Bool. RULING 4 made the
    /// protocol throwing so that this case cannot be collapsed into `true` by an implementor.
    var emptinessIsUndeterminable = false

    struct EmptinessUnknown: Error {}

    func cancelSync() async {
        await onCancelSync?()
        events.append(.cancelSync)
    }
    func storeIsEmpty() throws -> Bool {
        if emptinessIsUndeterminable { throw EmptinessUnknown() }
        return isEmpty
    }
    func wipeStore() async {
        await onWipeStore?()
        events.append(.wipeStore)
        isEmpty = true
    }
    func configureSync(for state: AuthState, client: SupabaseClient?) {
        if let defaults = defaultsForOwnerLookup {
            ownerAtConfigure = StoreOwner.load(defaults: defaults).userID
        }
        stateAtConfigure = state
        events.append(.configureSync(String(describing: state)))
    }
}

/// A session store that cannot clear itself. The SDK's own `signOut` has no way to report this
/// (addendum obligation 1), so the service has to, and this is what proves it does.
private struct UnclearableSessionStore: SessionItemStore {
    enum Mode: Sendable {
        /// The keychain refuses the delete.
        case removalThrows
        /// The delete reports success and the item is still there afterwards.
        case itemSurvives
        /// The real shape of a locked or damaged keychain, which the two modes above do not model:
        /// `SecItemCopyMatching` returns `errSecInteractionNotAllowed` for an inaccessible item, so
        /// `KeychainSessionStorage.retrieve` throws rather than returning data. The read-back has
        /// to treat that as "still present", not as "gone".
        case retrieveThrows
    }

    let mode: Mode

    func store(key: String, value: Data) throws {}

    func retrieve(key: String) throws -> Data? {
        switch mode {
        case .itemSurvives: return Data("a session that outlived the sign-out".utf8)
        case .retrieveThrows: throw KeychainSessionStorage.Failure.keychain(errSecInteractionNotAllowed)
        case .removalThrows: return nil
        }
    }

    func remove(key: String) throws {
        if mode == .removalThrows { throw KeychainSessionStorage.Failure.keychain(errSecInteractionNotAllowed) }
    }

    func removeAll() throws {
        if mode == .removalThrows { throw KeychainSessionStorage.Failure.keychain(errSecInteractionNotAllowed) }
    }
}

/// A keychain that lets the first sweep through and then reports the session item back. That is
/// the shape of the F1 race: `stopAutoRefresh()` does not cancel a refresh already awaiting the
/// network, so `update(session)` can write the item again after the read-back proved it gone.
private final class ResurrectingSessionStore: SessionItemStore, @unchecked Sendable {
    private var sweeps = 0

    func store(key: String, value: Data) throws {}

    func retrieve(key: String) throws -> Data? {
        sweeps > 1 && key == AuthService.sessionStorageKey
            ? Data("a session a refresh wrote back".utf8)
            : nil
    }

    func remove(key: String) throws {}

    func removeAll() throws { sweeps += 1 }
}

/// A `UserDefaults` whose writes to one key do not stick. `StoreOwner.save` is silent on both of
/// its failure modes, so this is the only way to drive the case where the ownership claim does not
/// reach disk.
private final class OwnerWriteDroppingDefaults: UserDefaults {
    override func set(_ value: Any?, forKey defaultName: String) {
        guard defaultName != StoreOwner.defaultsKey else { return }
        super.set(value, forKey: defaultName)
    }
}

/// A nonce mismatch as the server reports it: no error code, only the message text.
private struct ServerNonceMismatch: Error, LocalizedError {
    var errorDescription: String? { "Nonces mismatch" }
}

@MainActor
final class AuthServiceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    /// Unique per test run, so no case here can touch the app's real keychain items and two runs
    /// on the same machine cannot collide.
    private var keychainService: String!
    private var sessionStorage: KeychainSessionStorage!
    private var lifecycle: FakeStoreLifecycle!
    private let userA = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let userB = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    override func setUpWithError() throws {
        suiteName = "AuthServiceTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        keychainService = "com.ashlab.AnimalTracker.auth.authtests.\(UUID().uuidString)"
        sessionStorage = KeychainSessionStorage(service: keychainService)
        lifecycle = FakeStoreLifecycle()
    }

    override func tearDownWithError() throws {
        // Sweep the throwaway service and the throwaway suite, so a failed assertion cannot leave
        // a keychain item or a defaults blob behind.
        try? sessionStorage.removeAll()
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeService(isRelease: Bool = false) -> AuthService {
        let auth = AuthService(config: nil,
                               defaults: defaults,
                               isRelease: isRelease,
                               sessionStorage: sessionStorage)
        auth.lifecycle = lifecycle
        return auth
    }

    // MARK: configuration

    func testUnconfiguredServiceHasNoClient() {
        let auth = makeService()
        XCTAssertFalse(auth.isConfigured)
        XCTAssertEqual(auth.state, .unknown)
    }

    func testDebugBuildWithoutAKeyGoesOffline() async {
        let auth = makeService(isRelease: false)
        await auth.restoreSession()
        XCTAssertEqual(auth.state, .offline)
    }

    /// Fail closed: a release build with no key must never reach the tabs.
    func testReleaseBuildWithoutAKeyIsMisconfigured() async {
        let auth = makeService(isRelease: true)
        await auth.restoreSession()
        XCTAssertEqual(auth.state, .misconfigured)
    }

    /// Addendum obligation 2. The options are recorded whether or not a client was built, so the
    /// session's keychain service and storage key are asserted without constructing a client and
    /// therefore without a network. A refactor that points the session somewhere else fails here.
    func testTheClientIsBuiltWithTheAppsPinnedKeychainService() {
        let auth = AuthService(config: nil, defaults: defaults, isRelease: false)
        let storage = auth.clientOptions.auth.storage as? KeychainSessionStorage
        XCTAssertEqual(storage?.service, KeychainSessionStorage.defaultService)
        XCTAssertEqual(auth.clientOptions.auth.storageKey, AuthService.sessionStorageKey)
        XCTAssertEqual((auth.sessionStorage as? KeychainSessionStorage)?.service,
                       KeychainSessionStorage.defaultService,
                       "the storage the service clears by hand is the storage the client was built with")
        // Not cosmetic. `LiveSessionManager.refreshSession` puts the raw refresh token into the
        // logger's task-local context (`Sources/Auth/Internal/SessionManager.swift:68-72`), and the
        // SDK's request logging would write the body of `POST /token?grant_type=id_token`, which
        // carries the Apple identity token and the raw nonce. The nil default is the only thing
        // keeping both out of a log.
        XCTAssertNil(auth.clientOptions.global.logger, "no logger may ever be configured on this client")
    }

    /// The SDK derives the PKCE item's name from the storage key, so this app can name both items
    /// it has to be able to remove (addendum obligation 3).
    /// Asserted as a literal, not as the interpolation that defines the constant. Restating the
    /// definition cannot fail; this fails if either half is renamed, which is the regression that
    /// would leave the PKCE item unnamed and unswept.
    func testTheCodeVerifierKeyFollowsTheSDKsOwnNaming() {
        XCTAssertEqual(AuthService.sessionStorageKey, "animalTracker.session")
        XCTAssertEqual(AuthService.codeVerifierStorageKey, "animalTracker.session-code-verifier")
    }

    /// F6. Every other case in this file passes `config: nil`, so no `if let client` branch is
    /// ever executed and the whole half of the file that has a client is structurally uncovered.
    /// This closes as much of that as is possible offline: a real `SupabaseClient`, built on the
    /// injected throwaway keychain service, driven through `restoreSession()`'s no-stored-session
    /// branch. `currentSession` is `sessionStorage.get()` (`Sources/Auth/AuthClient.swift:201-203`),
    /// a keychain read and nothing more, so this reaches the branch with no network at all. The
    /// loopback URL is never contacted; it is there so `SupabaseConfig.make` returns non-nil.
    func testRestoreSessionWithAClientAndNoStoredSessionSignsOutWithNoNetwork() async {
        let config = SupabaseConfig.make(url: "https://127.0.0.1", anonKey: "anon-key-placeholder")
        XCTAssertNotNil(config, "the loopback config has to build or this test proves nothing")
        let auth = AuthService(config: config,
                               defaults: defaults,
                               isRelease: false,
                               sessionStorage: sessionStorage)
        auth.lifecycle = lifecycle
        XCTAssertTrue(auth.isConfigured, "this is the configured path, not the nil-client path")

        await auth.restoreSession()

        XCTAssertEqual(auth.state, .signedOut)
        XCTAssertEqual(lifecycle.events, [.configureSync(String(describing: AuthState.signedOut))])
    }

    // MARK: store ownership, the one ordered transition

    func testSigningInAsTheSameUserKeepsTheStore() async {
        StoreOwner(userID: userA.uuidString.lowercased(), claimedAt: Date()).save(defaults: defaults)
        lifecycle.isEmpty = false
        var state = SyncState()
        state.setPushedThrough(.animals, Date(timeIntervalSince1970: 500))
        state.save(defaults: defaults)

        let auth = makeService()
        await auth.establish(userID: userA, email: "ash@example.com")

        XCTAssertEqual(lifecycle.events.count, 1)
        guard case .configureSync = lifecycle.events[0] else { return XCTFail("expected configureSync") }
        XCTAssertEqual(SyncState.load(defaults: defaults).pushedThrough(.animals),
                       Date(timeIntervalSince1970: 500), "the watermarks survive a same-user sign-in")
        XCTAssertEqual(auth.state, .signedIn(userID: userA, email: "ash@example.com"))
    }

    func testSigningInAsADifferentUserCancelsSyncThenWipesThenConfigures() async {
        StoreOwner(userID: userB.uuidString.lowercased(), claimedAt: Date()).save(defaults: defaults)
        lifecycle.isEmpty = false
        var state = SyncState()
        state.setPushedThrough(.animals, Date(timeIntervalSince1970: 500))
        state.save(defaults: defaults)

        let auth = makeService()
        await auth.establish(userID: userA, email: nil)

        XCTAssertEqual(lifecycle.events.prefix(2).map { $0 }, [.cancelSync, .wipeStore],
                       "cancel the running sync before destroying the store it is writing to")
        XCTAssertEqual(lifecycle.events.count, 3)
        XCTAssertEqual(SyncState.load(defaults: defaults).pushedThrough(.animals), SyncState.epoch)
        XCTAssertEqual(StoreOwner.load(defaults: defaults).userID, userA.uuidString.lowercased())
    }

    /// Data made offline or before sign-in is never adopted into an account.
    func testSigningInOverUnownedNonEmptyDataWipes() async {
        StoreOwner.clear(defaults: defaults)
        lifecycle.isEmpty = false

        let auth = makeService()
        await auth.establish(userID: userA, email: nil)

        XCTAssertTrue(lifecycle.events.contains(.wipeStore))
    }

    /// Fresh install: the keychain still holds a session, the store is empty, nobody owns it.
    /// Nothing to wipe, but the watermarks have to start from scratch.
    func testFirstLaunchAfterInstallClaimsTheEmptyStoreAndResetsWatermarks() async {
        StoreOwner.clear(defaults: defaults)
        lifecycle.isEmpty = true
        var state = SyncState()
        state.setPullCursor(.animals, Date(timeIntervalSince1970: 900), offset: 3)
        state.save(defaults: defaults)

        let auth = makeService()
        await auth.establish(userID: userA, email: nil)

        XCTAssertFalse(lifecycle.events.contains(.wipeStore))
        XCTAssertEqual(SyncState.load(defaults: defaults).pullCursor(.animals), SyncState.epoch)
        XCTAssertEqual(SyncState.load(defaults: defaults).pullOffset(.animals), 0)
    }

    /// Fail closed. With no lifecycle attached there is no way to ask whether the store is empty,
    /// and "I do not know" must mean "assume it holds someone's records", so an unowned store is
    /// reset rather than adopted. The v2 code defaulted the other way.
    func testAServiceWithNoLifecycleFailsClosedAndResetsTheStore() async {
        StoreOwner.clear(defaults: defaults)
        var state = SyncState()
        state.setPullCursor(.animals, Date(timeIntervalSince1970: 900), offset: 3)
        state.save(defaults: defaults)

        let auth = AuthService(config: nil,
                               defaults: defaults,
                               isRelease: false,
                               sessionStorage: sessionStorage)
        XCTAssertNil(auth.lifecycle)
        await auth.establish(userID: userA, email: nil)

        // `reset` calls SyncState.clear, which removes the blob. `claimEmpty` would call
        // forgetSyncHistory and save, leaving a blob behind. That is the only observable difference
        // between the two branches when no lifecycle is attached, so it is what this asserts.
        XCTAssertNil(defaults.data(forKey: SyncState.defaultsKey),
                     "an unknown store must take the reset branch, not claimEmpty")
        XCTAssertEqual(StoreOwner.load(defaults: defaults).userID, userA.uuidString.lowercased())
    }

    /// The same decision with a lifecycle that says the store is empty goes the other way, so the
    /// assertion above is about the missing lifecycle and not about `StoreOwnerPolicy`.
    func testAnEmptyStoreWithALifecycleStillTakesTheClaimBranch() async {
        StoreOwner.clear(defaults: defaults)
        lifecycle.isEmpty = true
        SyncState().save(defaults: defaults)

        let auth = makeService()
        await auth.establish(userID: userA, email: nil)

        XCTAssertNotNil(defaults.data(forKey: SyncState.defaultsKey))
        XCTAssertFalse(lifecycle.events.contains(.wipeStore))
    }

    /// An ownership record this build cannot read is a fault, not a fresh install, and the
    /// three-case entry point is what tells them apart. Keeping is the whole point of commit
    /// 575b376: a corrupt sidecar must not cost someone their unpushed records.
    func testAnUnreadableOwnershipRecordKeepsTheStore() async {
        defaults.set(Data("not a StoreOwner".utf8), forKey: StoreOwner.defaultsKey)
        lifecycle.isEmpty = false
        var state = SyncState()
        state.setPushedThrough(.animals, Date(timeIntervalSince1970: 500))
        state.save(defaults: defaults)

        let auth = makeService()
        await auth.establish(userID: userA, email: nil)

        XCTAssertFalse(lifecycle.events.contains(.wipeStore))
        XCTAssertEqual(SyncState.load(defaults: defaults).pushedThrough(.animals),
                       Date(timeIntervalSince1970: 500))
        XCTAssertEqual(StoreOwner.load(defaults: defaults).userID, userA.uuidString.lowercased(),
                       "the fresh claim makes the record readable again")
    }

    /// Ownership is recorded the moment the session is established, before anything syncs.
    ///
    /// Asserted from *inside* `configureSync`, not after `establish` returns. Reading the owner
    /// afterwards cannot fail on the mutation it exists to catch: moving the claim write below
    /// `configureSync`, or below `state =`, leaves the owner recorded by the time the test looks
    /// and leaves `configureSync` the last event. This is the only test guarding the spec's
    /// central ownership rule.
    func testOwnershipIsRecordedBeforeSyncIsConfigured() async {
        lifecycle.defaultsForOwnerLookup = defaults
        let auth = makeService()
        await auth.establish(userID: userA, email: nil)

        XCTAssertEqual(lifecycle.ownerAtConfigure, userA.uuidString.lowercased(),
                       "the claim must already be on disk when sync is pointed at this user")
        XCTAssertEqual(lifecycle.stateAtConfigure, .signedIn(userID: userA, email: nil),
                       "and the state must already be .signedIn")
        XCTAssertNotNil(StoreOwner.load(defaults: defaults).claimedAt)
        guard case .configureSync = lifecycle.events.last else {
            return XCTFail("configureSync must be the last step of the transition, got \(lifecycle.events)")
        }
    }

    /// C2. `StoreOwner.save` is silent on both of its failure modes, and in the unreadable-record
    /// case the fresh claim is the only thing that restores the mismatch guard for the next person
    /// who signs in on this phone. A claim that did not reach disk must not reach sync.
    func testASignInWhoseOwnershipClaimDoesNotStickNeverReachesSignedIn() async throws {
        let suite = "AuthServiceTests-dropped-owner-\(UUID().uuidString)"
        let dropping = try XCTUnwrap(OwnerWriteDroppingDefaults(suiteName: suite))
        defer { dropping.removePersistentDomain(forName: suite) }

        let auth = AuthService(config: nil, defaults: dropping, isRelease: false, sessionStorage: sessionStorage)
        auth.lifecycle = lifecycle
        await auth.establish(userID: userA, email: nil)

        XCTAssertEqual(auth.state, .signedOut, "an unowned store must not be presented as signed in")
        XCTAssertEqual(auth.message, AnimalTracker.AuthError.ownershipNotRecorded.errorDescription)
        XCTAssertEqual(lifecycle.stateAtConfigure, .signedOut,
                       "sync is pointed at nothing, not at a user whose claim is missing")
    }

    /// RULING 4. `storeIsEmpty()` throws when it cannot tell, and the caller reads that as "not
    /// empty". An unowned store that cannot be inspected is reset rather than adopted, which is
    /// the direction that cannot hand one person's animals to another.
    func testAStoreWhoseEmptinessCannotBeDeterminedIsResetRatherThanAdopted() async {
        StoreOwner.clear(defaults: defaults)
        lifecycle.isEmpty = true
        lifecycle.emptinessIsUndeterminable = true

        let auth = makeService()
        await auth.establish(userID: userA, email: nil)

        XCTAssertTrue(lifecycle.events.contains(.wipeStore),
                      "could not tell must mean could hold someone's records")
        XCTAssertNil(defaults.data(forKey: SyncState.defaultsKey),
                     "the reset branch clears the blob; claimEmpty would leave one")
    }

    // MARK: sign out

    func testSignOutCancelsSyncWipesThenClearsIds() async {
        StoreOwner(userID: userA.uuidString.lowercased(), claimedAt: Date()).save(defaults: defaults)
        var state = SyncState()
        state.setPushedThrough(.animals, Date(timeIntervalSince1970: 500))
        state.save(defaults: defaults)
        defaults.set("apple-user-id", forKey: AuthService.appleUserIDKey)

        let auth = makeService()
        let outcome = await auth.signOut()

        XCTAssertEqual(outcome, .signedOut)
        XCTAssertEqual(lifecycle.events.prefix(2).map { $0 }, [.cancelSync, .wipeStore])
        XCTAssertEqual(auth.state, .signedOut)
        XCTAssertNil(StoreOwner.load(defaults: defaults).userID)
        XCTAssertEqual(SyncState.load(defaults: defaults), SyncState())
        XCTAssertNil(defaults.string(forKey: AuthService.appleUserIDKey))
        XCTAssertNil(auth.message)
        XCTAssertNil(defaults.string(forKey: AuthService.pendingTeardownKey),
                     "a sign-out that finished leaves no retry marker behind")
    }

    /// RULING 1. `signOut()` is `@discardableResult` and non-throwing, so `await auth.signOut()`
    /// compiles with no `try` and no warning, which is how task-5-brief.md calls it twice and how
    /// both internal callers reach it.
    func testSignOutCanBeAwaitedWithItsResultDiscardedAndWithoutTry() async {
        let auth = makeService()
        await auth.signOut()
        XCTAssertEqual(auth.state, .signedOut)
    }

    /// F12. Two taps must not run two overlapping wipes.
    func testASecondSignOutWhileOneIsRunningIsRefused() async {
        let auth = makeService()
        var secondOutcome: SignOutOutcome?
        lifecycle.onWipeStore = { [weak auth] in
            // Re-entering from inside the first sign-out is the deterministic way to be "during"
            // it. A real second tap lands in one of the same suspension points.
            guard let auth else { return }
            XCTAssertTrue(auth.isSigningOut, "the busy flag is what the second tap has to see")
            secondOutcome = await auth.signOut()
        }
        let first = await auth.signOut()

        XCTAssertEqual(first, .signedOut)
        XCTAssertEqual(secondOutcome, .refused(.signOutAlreadyRunning))
        XCTAssertFalse(auth.isSigningOut, "the flag is cleared on the way out")
        XCTAssertEqual(lifecycle.events.filter { $0 == .wipeStore }.count, 1)
    }

    /// Addendum obligation 1. `AuthClient.signOut` cannot fail on a keychain write: the storage
    /// calls are wrapped in non-throwing closures that only log. So a sign-out that cannot clear
    /// the session item has to be reported as a failure here, and nothing may be wiped while the
    /// session may still be on the phone.
    func testASignOutWhoseKeychainRemovalFailsIsReportedAsAFailure() async {
        StoreOwner(userID: userA.uuidString.lowercased(), claimedAt: Date()).save(defaults: defaults)
        var state = SyncState()
        state.setPushedThrough(.animals, Date(timeIntervalSince1970: 500))
        state.save(defaults: defaults)

        let auth = AuthService(config: nil,
                               defaults: defaults,
                               isRelease: false,
                               sessionStorage: UnclearableSessionStore(mode: .removalThrows))
        auth.lifecycle = lifecycle
        // Start from a real session rather than `.unknown`, so "the person stays signed in" is
        // what the state assertion actually says.
        await auth.establish(userID: userA, email: nil)
        lifecycle.events.removeAll()
        let outcome = await auth.signOut()

        XCTAssertEqual(outcome, .refused(.sessionStillPresent))
        XCTAssertEqual(auth.message, AnimalTracker.AuthError.sessionStillPresent.errorDescription)
        XCTAssertEqual(auth.state, .signedIn(userID: userA, email: nil),
                       "a sign-out that did not clear the session is not a sign-out")
        // Not `events == []`: stopping the writers before the removal is required (F1), so
        // `cancelSync` is expected here. What may not happen is the destruction.
        XCTAssertFalse(lifecycle.events.contains(.wipeStore),
                       "nothing is wiped while the session may still be on this phone")
        XCTAssertEqual(lifecycle.events.last, .configureSync(String(describing: AuthState.signedIn(userID: userA, email: nil))),
                       "sync is put back, so a refused sign-out does not leave it dead until relaunch")
        XCTAssertEqual(StoreOwner.load(defaults: defaults).userID, userA.uuidString.lowercased())
        XCTAssertEqual(SyncState.load(defaults: defaults).pushedThrough(.animals),
                       Date(timeIntervalSince1970: 500))
    }

    /// The other half of obligation 1: a removal that reports success and leaves the item behind
    /// is the case "it did not throw" cannot catch, so the item is read back and checked.
    func testASignOutThatLeavesTheSessionItemBehindIsReportedAsAFailure() async {
        let auth = AuthService(config: nil,
                               defaults: defaults,
                               isRelease: false,
                               sessionStorage: UnclearableSessionStore(mode: .itemSurvives))
        auth.lifecycle = lifecycle
        await auth.establish(userID: userA, email: nil)
        lifecycle.events.removeAll()
        let outcome = await auth.signOut()

        XCTAssertEqual(outcome, .refused(.sessionStillPresent))
        XCTAssertEqual(auth.message, AnimalTracker.AuthError.sessionStillPresent.errorDescription)
        XCTAssertEqual(auth.state, .signedIn(userID: userA, email: nil))
        XCTAssertFalse(lifecycle.events.contains(.wipeStore))
    }

    /// F7. The real shape of a refusing keychain is remove-succeeds-and-retrieve-throws:
    /// `SecItemCopyMatching` returns `errSecInteractionNotAllowed` for an inaccessible item and
    /// `KeychainSessionStorage.retrieve` turns anything that is neither success nor
    /// `errSecItemNotFound` into a throw. A read-back that cannot read must mean "still present".
    func testASignOutWhoseReadBackThrowsIsReportedAsAFailure() async {
        let auth = AuthService(config: nil,
                               defaults: defaults,
                               isRelease: false,
                               sessionStorage: UnclearableSessionStore(mode: .retrieveThrows))
        auth.lifecycle = lifecycle
        await auth.establish(userID: userA, email: nil)
        lifecycle.events.removeAll()
        let outcome = await auth.signOut()

        XCTAssertEqual(outcome, .refused(.sessionStillPresent))
        XCTAssertEqual(auth.state, .signedIn(userID: userA, email: nil))
        XCTAssertFalse(lifecycle.events.contains(.wipeStore))
    }

    // MARK: F1, the session's writers

    /// F1, Critical. Every writer of the session item has to be stopped *before* the item is
    /// removed, so `cancelSync()` must observe the item still on disk. Two writers exist:
    /// an in-flight PostgREST or Storage request, whose token comes from `auth.session`
    /// (`Sources/Supabase/SupabaseClient.swift:464-471`) and whose refresh writes the keychain
    /// (`Sources/Auth/Internal/SessionManager.swift:102`, `:113-115`), and the auto-refresh loop,
    /// which is on by default (`Sources/Auth/Defaults.swift:35`) and ticks every 30 seconds
    /// (`Sources/Auth/Internal/Constants.swift:14`).
    func testSignOutStopsTheWritersBeforeRemovingTheSessionItem() async throws {
        try sessionStorage.store(key: AuthService.sessionStorageKey, value: Data("session".utf8))
        var itemPresentAtCancelSync: Bool?
        lifecycle.onCancelSync = { [sessionStorage] in
            itemPresentAtCancelSync = ((try? sessionStorage?.retrieve(key: AuthService.sessionStorageKey)) ?? nil) != nil
        }

        let auth = makeService()
        await auth.signOut()

        XCTAssertEqual(itemPresentAtCancelSync, true,
                       "cancelSync must run before the session item is removed, not after it")
        XCTAssertEqual(lifecycle.events.first, .cancelSync, "stopping the writers is the first step")
    }

    /// The other half of F1. `stopAutoRefresh()` is fire and forget
    /// (`Sources/Auth/AuthClient.swift:1525-1527` wraps it in a detached `Task`) and it does not
    /// cancel `inFlightRefreshTask` (`Sources/Auth/Internal/SessionManager.swift:75-78`), so a
    /// refresh already awaiting the network can still write a fresh session after the read-back
    /// proved the item gone. A writer firing between the removal and the wipe must therefore be
    /// detected and the item taken again, or the sign-out reports success over a live session on
    /// disk and the next launch signs the person straight back in.
    func testASessionWrittenBackDuringTheWipeIsRemovedBeforeTheSignOutCompletes() async throws {
        try sessionStorage.store(key: AuthService.sessionStorageKey, value: Data("session".utf8))
        lifecycle.onWipeStore = { [sessionStorage] in
            // Exactly what SessionManager.update(_:) does: store a fresh session under the key.
            try? sessionStorage?.store(key: AuthService.sessionStorageKey, value: Data("a refreshed session".utf8))
        }

        let auth = makeService()
        await auth.signOut()

        XCTAssertNil(try sessionStorage.retrieve(key: AuthService.sessionStorageKey),
                     "a session written back during the wipe must not survive the sign-out")
    }

    /// And when the second sweep cannot take it either, the sign-out says so rather than
    /// reporting success over a live session. The store is already gone by then, so the person is
    /// not told they are still signed in; the retry marker is what finishes the job next launch.
    func testASessionThatSurvivesTheSecondSweepIsReportedAndLeavesARetryMarker() async {
        let auth = AuthService(config: nil,
                               defaults: defaults,
                               isRelease: false,
                               sessionStorage: ResurrectingSessionStore())
        auth.lifecycle = lifecycle
        await auth.establish(userID: userA, email: nil)
        lifecycle.events.removeAll()

        let outcome = await auth.signOut()

        XCTAssertEqual(outcome, .refused(.sessionSurvivedSignOut))
        XCTAssertEqual(auth.message, AnimalTracker.AuthError.sessionSurvivedSignOut.errorDescription)
        XCTAssertNotEqual(auth.message, AnimalTracker.AuthError.sessionStillPresent.errorDescription,
                          "the person is not still signed in here, so that copy would be false")
        XCTAssertEqual(auth.state, .signedOut)
        XCTAssertTrue(lifecycle.events.contains(.wipeStore))
        XCTAssertEqual(defaults.string(forKey: AuthService.pendingTeardownKey),
                       PendingTeardown.signOut.rawValue)
    }

    /// A sign-out that completes really does take the session item with it.
    func testSignOutRemovesThePinnedSessionItem() async throws {
        try sessionStorage.store(key: AuthService.sessionStorageKey, value: Data("session".utf8))
        let auth = makeService()
        await auth.signOut()
        XCTAssertNil(try sessionStorage.retrieve(key: AuthService.sessionStorageKey))
        XCTAssertEqual(auth.state, .signedOut)
    }

    // MARK: F3, a refused teardown is durable

    /// A sign-out the keychain refused leaves a marker, so the intent survives a relaunch. Without
    /// it the person sees the message, the app keeps running, and the next launch finds the
    /// session item, establishes it and presents the tabs as a normal session: their sign-out is
    /// gone with no trace and they may reasonably believe it happened.
    func testARefusedSignOutLeavesARetryMarkerBehind() async {
        let auth = AuthService(config: nil,
                               defaults: defaults,
                               isRelease: false,
                               sessionStorage: UnclearableSessionStore(mode: .removalThrows))
        auth.lifecycle = lifecycle
        await auth.establish(userID: userA, email: nil)

        _ = await auth.signOut()

        XCTAssertEqual(defaults.string(forKey: AuthService.pendingTeardownKey),
                       PendingTeardown.signOut.rawValue)
    }

    /// And the next launch finishes it, before anything is established.
    func testTheNextLaunchRetriesARefusedSignOutBeforeEstablishingAnything() async throws {
        StoreOwner(userID: userA.uuidString.lowercased(), claimedAt: Date()).save(defaults: defaults)
        defaults.set("apple-user-id", forKey: AuthService.appleUserIDKey)
        defaults.set(PendingTeardown.signOut.rawValue, forKey: AuthService.pendingTeardownKey)
        try sessionStorage.store(key: AuthService.sessionStorageKey, value: Data("session".utf8))

        let auth = makeService()
        await auth.restoreSession()

        XCTAssertEqual(auth.state, .signedOut)
        XCTAssertTrue(lifecycle.events.contains(.wipeStore),
                      "the destructive half never ran the first time, so it runs now")
        XCTAssertNil(try sessionStorage.retrieve(key: AuthService.sessionStorageKey))
        XCTAssertNil(StoreOwner.load(defaults: defaults).userID)
        XCTAssertNil(defaults.string(forKey: AuthService.appleUserIDKey))
        XCTAssertNil(defaults.string(forKey: AuthService.pendingTeardownKey),
                     "the marker is cleared only once the keychain is verified clean")
    }

    /// A retry that fails again changes nothing and keeps the marker, and it must still refuse to
    /// establish: a store whose session the keychain will not release is not a session to restore.
    func testASignOutRetryThatFailsAgainKeepsTheMarkerAndRefusesToEstablish() async {
        StoreOwner(userID: userA.uuidString.lowercased(), claimedAt: Date()).save(defaults: defaults)
        defaults.set(PendingTeardown.signOut.rawValue, forKey: AuthService.pendingTeardownKey)

        let auth = AuthService(config: nil,
                               defaults: defaults,
                               isRelease: false,
                               sessionStorage: UnclearableSessionStore(mode: .removalThrows))
        auth.lifecycle = lifecycle
        await auth.restoreSession()

        XCTAssertEqual(auth.state, .signedOut, "not signed back in")
        XCTAssertEqual(auth.message, AnimalTracker.AuthError.sessionStillPresent.errorDescription)
        XCTAssertFalse(lifecycle.events.contains(.wipeStore), "nothing is destroyed while the item is still there")
        XCTAssertEqual(defaults.string(forKey: AuthService.pendingTeardownKey),
                       PendingTeardown.signOut.rawValue, "the retry survives another launch")
    }

    /// The same mechanism for a deletion whose keychain sweep failed. Without it `restoreSession()`
    /// reads a non-nil `currentSession`, the refresh 401s because the sessions row cascade-deleted
    /// with the user, the SDK's own cleanup delete is swallowed by the same refusing keychain
    /// (`Sources/Auth/Internal/SessionStorage.swift:75-81`), and the app establishes a deleted user.
    func testTheNextLaunchRetriesARefusedAccountDeletionAndSaysSo() async {
        defaults.set(PendingTeardown.accountDeleted.rawValue, forKey: AuthService.pendingTeardownKey)

        let auth = AuthService(config: nil,
                               defaults: defaults,
                               isRelease: false,
                               sessionStorage: UnclearableSessionStore(mode: .removalThrows))
        auth.lifecycle = lifecycle
        await auth.restoreSession()

        XCTAssertEqual(auth.state, .signedOut, "never signed in as a user that no longer exists")
        XCTAssertEqual(auth.message, AnimalTracker.AuthError.accountDeletionIncomplete.errorDescription,
                       "not the sign-out copy: there is no account left to sign out of")
        XCTAssertEqual(defaults.string(forKey: AuthService.pendingTeardownKey),
                       PendingTeardown.accountDeleted.rawValue)
    }

    /// And the succeeding retry clears it.
    func testADeletionRetryThatSucceedsClearsTheMarker() async {
        defaults.set(PendingTeardown.accountDeleted.rawValue, forKey: AuthService.pendingTeardownKey)

        let auth = makeService()
        await auth.restoreSession()

        XCTAssertEqual(auth.state, .signedOut)
        XCTAssertNil(defaults.string(forKey: AuthService.pendingTeardownKey))
        XCTAssertNil(auth.message)
    }

    /// The previous revision asserted the opposite. Offline data has no owner, so leaving offline
    /// mode discards it rather than letting the next sign-in adopt it.
    func testLeavingOfflineModeDiscardsTheOfflineData() async {
        let auth = makeService()
        auth.continueOffline()
        XCTAssertEqual(auth.state, .offline)

        await auth.leaveOfflineMode()

        XCTAssertEqual(auth.state, .signedOut)
        XCTAssertTrue(lifecycle.events.contains(.wipeStore))
        XCTAssertNil(StoreOwner.load(defaults: defaults).userID)
    }

    // MARK: nonce

    func testBeginSignInReturnsTheHashAndMarksTheServiceBusy() throws {
        let auth = makeService()
        let hash = try auth.beginSignIn()
        XCTAssertEqual(hash.count, 64, "hex digest of SHA-256")
        XCTAssertTrue(hash.allSatisfy { "0123456789abcdef".contains($0) })
        XCTAssertTrue(auth.isWorking)
    }

    func testTwoSignInAttemptsUseDifferentNonces() throws {
        let auth = makeService()
        let first = try auth.beginSignIn()
        auth.abortSignIn(message: "")
        XCTAssertNotEqual(first, try auth.beginSignIn())
    }

    /// A second tap while the first attempt is still live would overwrite `pendingRawNonce`, so
    /// the first authorization's completion would be exchanged against the second nonce, rejected
    /// by the server, and read as a nonce mismatch: a client-side mistake moving the digest
    /// encoding on. Refuse instead.
    func testASecondSignInWhileOneIsRunningIsRefused() throws {
        let auth = makeService()
        _ = try auth.beginSignIn()
        XCTAssertThrowsError(try auth.beginSignIn()) { error in
            XCTAssertEqual(error as? AnimalTracker.AuthError, .signInAlreadyInProgress)
        }
        XCTAssertTrue(auth.isWorking, "the first attempt is still the live one")
    }

    /// A cancelled Apple sheet reaches `abortSignIn` and nothing else: `SignInWithAppleButton`
    /// reports it as `.failure(ASAuthorizationError.canceled)`, so `signInWithApple` is never
    /// called. Both the busy flag and the pending nonce have to be cleared there or the button
    /// stays busy until the app is relaunched.
    func testACancelledSignInClearsTheBusyFlagAndTheNonceWithNoMessage() async {
        let auth = makeService()
        _ = try? auth.beginSignIn()
        auth.abortSignIn(message: "")

        XCTAssertFalse(auth.isWorking)
        XCTAssertNil(auth.message, "an empty message means say nothing, not show a blank line")
        do {
            try await auth.exchange(idToken: "id-token-placeholder", appleUserID: "apple-user", email: nil)
            XCTFail("expected AuthError.nonceUnavailable")
        } catch AnimalTracker.AuthError.nonceUnavailable {
            // expected: the nonce went with the cancel
        } catch {
            XCTFail("expected AuthError.nonceUnavailable, got \(error)")
        }
    }

    /// Fail closed: if the request could not be prepared, the pending nonce is dropped, so a
    /// completion that still arrives has nothing to exchange and `signInWithApple` throws
    /// `nonceUnavailable` before it ever looks at the credential.
    func testAbortingASignInDropsThePendingNonceAndLeavesTheStateAlone() {
        let auth = makeService()
        _ = try? auth.beginSignIn()
        auth.abortSignIn(message: "could not start")
        XCTAssertFalse(auth.isWorking)
        XCTAssertEqual(auth.message, "could not start")
        XCTAssertEqual(auth.state, .unknown)
    }

    /// The completion that arrives after an abort. No ASAuthorization is needed to drive this:
    /// the exchange is entered with the credential already unwrapped.
    func testAnExchangeAfterAnAbortedSignInHasNothingToExchange() async {
        let auth = makeService()
        _ = try? auth.beginSignIn()
        auth.abortSignIn(message: "could not start")
        do {
            try await auth.exchange(idToken: "id-token-placeholder", appleUserID: "apple-user", email: nil)
            XCTFail("expected AuthError.nonceUnavailable")
        } catch AnimalTracker.AuthError.nonceUnavailable {
            // expected
        } catch {
            XCTFail("expected AuthError.nonceUnavailable, got \(error)")
        }
        XCTAssertFalse(auth.isWorking)
    }

    /// Addendum obligation 5. One nonce serves exactly one authorization, whatever becomes of it,
    /// so a retry after a failed exchange cannot reuse the identity token Apple already signed:
    /// it has to go back through `beginSignIn()` for a fresh Apple round trip.
    func testOneNonceServesExactlyOneExchangeSoARetryNeedsAFreshAppleRoundTrip() async {
        let auth = makeService()
        _ = try? auth.beginSignIn()

        do {
            try await auth.exchange(idToken: "id-token-placeholder", appleUserID: "apple-user", email: nil)
            XCTFail("expected AuthError.notConfigured")
        } catch AnimalTracker.AuthError.notConfigured {
            // expected: the nonce is taken before the client is looked at
        } catch {
            XCTFail("expected AuthError.notConfigured, got \(error)")
        }

        do {
            try await auth.exchange(idToken: "id-token-placeholder", appleUserID: "apple-user", email: nil)
            XCTFail("expected AuthError.nonceUnavailable")
        } catch AnimalTracker.AuthError.nonceUnavailable {
            // expected: the nonce is gone, a retry has to start at beginSignIn()
        } catch {
            XCTFail("expected AuthError.nonceUnavailable, got \(error)")
        }
    }

    /// v2 had a `testAnUnconfiguredServiceNeverSignsAnyoneIn` here that asserted exactly what
    /// `testUnconfiguredServiceHasNoClient` already asserts, so it could not fail. This one drives
    /// a code path: the destructive operation refuses without a client, and refuses *before*
    /// touching the store, so a misconfigured build cannot wipe a person's records.
    func testAnUnconfiguredServiceRefusesToDeleteAnAccount() async {
        let auth = makeService()
        do {
            try await auth.deleteAccount()
            XCTFail("expected AuthError.notConfigured")
        } catch AnimalTracker.AuthError.notConfigured {
            // expected
        } catch {
            XCTFail("expected AuthError.notConfigured, got \(error)")
        }
        XCTAssertFalse(lifecycle.events.contains(.cancelSync), "nothing may be cancelled without a client")
        XCTAssertFalse(lifecycle.events.contains(.wipeStore), "nothing may be wiped without a client")
        XCTAssertFalse(auth.isWorking)
        XCTAssertEqual(auth.state, .unknown)
    }

    func testNonceMismatchIsRecognisedFromTheServerMessage() {
        XCTAssertTrue(AuthService.isNonceMismatch(ServerNonceMismatch()))
        XCTAssertFalse(AuthService.isNonceMismatch(URLError(.timedOut)))
    }

    /// Addendum obligation 4. The encoding is only ever persisted by a sign-in that worked. A
    /// mismatch moves the next attempt to base64url in memory and writes nothing, and a base64url
    /// attempt that also fails puts hex back, so two failures in a row can never pin the app to
    /// an encoding it has no way home from (`base64url.next` is nil).
    func testTwoFailedSignInsNeverLeaveTheStoredEncodingAtBase64url() {
        let auth = makeService()
        XCTAssertEqual(auth.nonceEncodingForNextAttempt, .hex)

        let first = auth.resolveSignInFailure(ServerNonceMismatch())
        XCTAssertEqual(first as? AnimalTracker.AuthError, .nonceMismatch,
                       "a mismatch is reported as AuthError.nonceMismatch, got \(first)")
        XCTAssertEqual(auth.nonceEncodingForNextAttempt, .base64url, "the fallback is tried next")
        XCTAssertNil(defaults.string(forKey: NonceEncoding.defaultsKey),
                     "nothing is persisted until a sign-in actually succeeds")

        _ = auth.resolveSignInFailure(ServerNonceMismatch())
        XCTAssertEqual(auth.nonceEncodingForNextAttempt, .hex, "the fallback is exhausted, so hex comes back")
        // `NonceEncoding.load` also returns `.hex` when nothing is stored, so asserting on `load`
        // alone passes with the hex write deleted. The on-disk half of obligation 4 needs the
        // stored string itself.
        XCTAssertEqual(defaults.string(forKey: NonceEncoding.defaultsKey), NonceEncoding.hex.rawValue,
                       "hex is written back, not merely defaulted to")
        XCTAssertEqual(NonceEncoding.load(defaults: defaults), .hex,
                       "two failures in a row must not leave the stored encoding at base64url")
    }

    /// An ordinary failure is handed back untouched and moves nothing.
    func testAnOrdinarySignInFailureLeavesTheEncodingAlone() {
        let auth = makeService()
        let error = auth.resolveSignInFailure(URLError(.timedOut))
        XCTAssertTrue(error is URLError)
        XCTAssertEqual(auth.nonceEncodingForNextAttempt, .hex)
        XCTAssertNil(defaults.string(forKey: NonceEncoding.defaultsKey))
    }

    /// The persisted preference is honoured at launch, and the service starts from it.
    func testAStoredEncodingIsTheOneTheNextAttemptUses() {
        NonceEncoding.base64url.save(defaults: defaults)
        XCTAssertEqual(makeService().nonceEncodingForNextAttempt, .base64url)
    }

    // MARK: state

    func testAuthStateEquatability() {
        XCTAssertEqual(AuthState.signedIn(userID: userA, email: "x@y.z"), .signedIn(userID: userA, email: "x@y.z"))
        XCTAssertNotEqual(AuthState.signedIn(userID: userA, email: nil), .signedIn(userID: userA, email: "x@y.z"))
        XCTAssertNotEqual(AuthState.offline, .signedOut)
        XCTAssertNotEqual(AuthState.misconfigured, .offline)
    }

    // MARK: Apple credential state (verification defect D-D8)

    /// Drives `checkAppleCredentialState()` with a substituted probe. The service is put into
    /// `.signedIn` through `establish`, which is the only state the check acts in, and the
    /// lifecycle's event log is cleared afterwards so the assertions see only what the check did.
    private func signedInService(
        probe: @escaping (String) async -> (ASAuthorizationAppleIDProvider.CredentialState, (any Error)?)
    ) async -> AuthService {
        let auth = makeService()
        await auth.establish(userID: userA, email: nil)
        defaults.set("apple.user.id", forKey: AuthService.appleUserIDKey)
        lifecycle.events.removeAll()
        auth.credentialStateProbe = probe
        return auth
    }

    func testARevokedAppleCredentialSignsOut() async {
        let auth = await signedInService { _ in (.revoked, nil) }
        await auth.checkAppleCredentialState()
        XCTAssertEqual(auth.state, .signedOut)
        XCTAssertEqual(lifecycle.events.prefix(2).map { $0 }, [.cancelSync, .wipeStore],
                       "a real revocation is the one case that wipes, and it cancels first")
        XCTAssertNil(StoreOwner.load(defaults: defaults).userID)
    }

    /// RULING 3. Revoking an Apple credential does not invalidate the Supabase session, so the
    /// final push would usually succeed and the records created since the last sync are savable.
    /// Revocation therefore attempts the same push the Settings button does, with the same bound.
    func testARevocationAttemptsTheFinalPushBeforeDestroyingAnything() async {
        let auth = await signedInService { _ in (.revoked, nil) }
        let fake = lifecycle!
        var pushTimeout: TimeInterval?
        var eventsAtPush: [FakeStoreLifecycle.Event]?
        auth.finalPushBeforeSignOut = { timeout in
            pushTimeout = timeout
            eventsAtPush = fake.events
            return true
        }

        await auth.checkAppleCredentialState()

        XCTAssertEqual(pushTimeout, AuthService.finalPushTimeout)
        XCTAssertEqual(AuthService.finalPushTimeout, 20, "the same bound the Settings button uses")
        XCTAssertEqual(eventsAtPush, [], "the push runs before sync is cancelled, or it cannot push")
        XCTAssertEqual(auth.state, .signedOut)
    }

    /// And it proceeds whatever the push returned. There is nobody looking at the phone, so a
    /// confirmation is not available; a revoked credential is not a decision that can wait.
    func testARevocationProceedsEvenWhenTheFinalPushFails() async {
        let auth = await signedInService { _ in (.revoked, nil) }
        auth.finalPushBeforeSignOut = { _ in false }

        await auth.checkAppleCredentialState()

        XCTAssertEqual(auth.state, .signedOut)
        XCTAssertTrue(lifecycle.events.contains(.wipeStore))
    }

    /// A3 and C5. The revocation observer used to call `signOut()` flat, so a notification could
    /// run the full destructive path in a build that cannot sign in: `client` is nil there, the
    /// keychain sweep deletes nothing and does not throw, and the wipe went ahead. It now carries
    /// the same two guards `checkAppleCredentialState()` has.
    func testARevocationNotificationDoesNothingOutsideASignedInSession() async {
        let auth = makeService()
        defaults.set("apple.user.id", forKey: AuthService.appleUserIDKey)

        await auth.handleCredentialRevocation()

        XCTAssertEqual(auth.state, .unknown, "a revocation is meaningless in a state with no credential")
        XCTAssertFalse(lifecycle.events.contains(.wipeStore))
    }

    /// The other guard: signed in, but this phone never recorded an Apple id, so there is nothing
    /// a revocation could be about.
    func testARevocationNotificationDoesNothingWithNoStoredAppleID() async {
        let auth = makeService()
        await auth.establish(userID: userA, email: nil)
        defaults.removeObject(forKey: AuthService.appleUserIDKey)
        lifecycle.events.removeAll()

        await auth.handleCredentialRevocation()

        XCTAssertEqual(auth.state, .signedIn(userID: userA, email: nil))
        XCTAssertFalse(lifecycle.events.contains(.wipeStore))
    }

    /// The positive case, so the guards above are about the guards and not about a dead path.
    func testARevocationNotificationInASignedInSessionSignsOut() async {
        let auth = makeService()
        await auth.establish(userID: userA, email: nil)
        defaults.set("apple.user.id", forKey: AuthService.appleUserIDKey)
        lifecycle.events.removeAll()

        await auth.handleCredentialRevocation()

        XCTAssertEqual(auth.state, .signedOut)
        XCTAssertTrue(lifecycle.events.contains(.wipeStore))
    }

    /// C9. `restoreSession()` calls `checkAppleCredentialState()` unconditionally, so the guard
    /// there is the only thing stopping a `.revoked` probe wiping a store in a state that never
    /// signed in.
    func testTheCredentialCheckDoesNothingOutsideASignedInSession() async {
        let auth = makeService()
        defaults.set("apple.user.id", forKey: AuthService.appleUserIDKey)
        auth.credentialStateProbe = { _ in (.revoked, nil) }

        await auth.checkAppleCredentialState()

        XCTAssertEqual(auth.state, .unknown)
        XCTAssertEqual(lifecycle.events, [])
    }


    /// `.notFound` also means "a different Apple ID is signed in on this device". Wiping on it
    /// would delete every unpushed record for a condition that is not a revocation.
    func testANotFoundAppleCredentialLeavesTheSessionAndTheStoreAlone() async {
        let auth = await signedInService { _ in (.notFound, nil) }
        await auth.checkAppleCredentialState()
        XCTAssertEqual(auth.state, .signedIn(userID: userA, email: nil))
        XCTAssertEqual(lifecycle.events, [], "nothing may touch the store on an ambiguous state")
    }

    func testATransferredAppleCredentialLeavesTheSessionAndTheStoreAlone() async {
        let auth = await signedInService { _ in (.transferred, nil) }
        await auth.checkAppleCredentialState()
        XCTAssertEqual(auth.state, .signedIn(userID: userA, email: nil))
        XCTAssertEqual(lifecycle.events, [])
    }

    /// The error path. Whatever state accompanies a non-nil error is not trustworthy, so the
    /// service must ignore both and let the next authenticated request decide.
    func testAFailedCredentialProbeLeavesTheSessionAndTheStoreAlone() async {
        struct Transient: Error {}
        let auth = await signedInService { _ in (.notFound, Transient()) }
        await auth.checkAppleCredentialState()
        XCTAssertEqual(auth.state, .signedIn(userID: userA, email: nil))
        XCTAssertEqual(lifecycle.events, [])
    }
}
