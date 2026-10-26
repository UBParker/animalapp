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

    func cancelSync() async { events.append(.cancelSync) }
    func storeIsEmpty() -> Bool { isEmpty }
    func wipeStore() async {
        events.append(.wipeStore)
        isEmpty = true
    }
    func configureSync(for state: AuthState, client: SupabaseClient?) {
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
    }

    let mode: Mode

    func store(key: String, value: Data) throws {}

    func retrieve(key: String) throws -> Data? {
        mode == .itemSurvives ? Data("a session that outlived the sign-out".utf8) : nil
    }

    func remove(key: String) throws {
        if mode == .removalThrows { throw KeychainSessionStorage.Failure.keychain(errSecInteractionNotAllowed) }
    }

    func removeAll() throws {
        if mode == .removalThrows { throw KeychainSessionStorage.Failure.keychain(errSecInteractionNotAllowed) }
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
    }

    /// The SDK derives the PKCE item's name from the storage key, so this app can name both items
    /// it has to be able to remove (addendum obligation 3).
    func testTheCodeVerifierKeyFollowsTheSDKsOwnNaming() {
        XCTAssertEqual(AuthService.codeVerifierStorageKey, "\(AuthService.sessionStorageKey)-code-verifier")
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
    func testOwnershipIsRecordedBeforeSyncIsConfigured() async {
        let auth = makeService()
        await auth.establish(userID: userA, email: nil)
        XCTAssertEqual(StoreOwner.load(defaults: defaults).userID, userA.uuidString.lowercased())
        XCTAssertNotNil(StoreOwner.load(defaults: defaults).claimedAt)
        guard case .configureSync = lifecycle.events.last else {
            return XCTFail("configureSync must be the last step of the transition, got \(lifecycle.events)")
        }
    }

    // MARK: sign out

    func testSignOutCancelsSyncWipesThenClearsIds() async {
        StoreOwner(userID: userA.uuidString.lowercased(), claimedAt: Date()).save(defaults: defaults)
        var state = SyncState()
        state.setPushedThrough(.animals, Date(timeIntervalSince1970: 500))
        state.save(defaults: defaults)
        defaults.set("apple-user-id", forKey: AuthService.appleUserIDKey)

        let auth = makeService()
        await auth.signOut()

        XCTAssertEqual(lifecycle.events.prefix(2).map { $0 }, [.cancelSync, .wipeStore])
        XCTAssertEqual(auth.state, .signedOut)
        XCTAssertNil(StoreOwner.load(defaults: defaults).userID)
        XCTAssertEqual(SyncState.load(defaults: defaults), SyncState())
        XCTAssertNil(defaults.string(forKey: AuthService.appleUserIDKey))
        XCTAssertNil(auth.message)
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
        await auth.signOut()

        XCTAssertEqual(auth.message, AnimalTracker.AuthError.sessionStillPresent.errorDescription)
        XCTAssertNotEqual(auth.state, .signedOut, "a sign-out that did not clear the session is not a sign-out")
        XCTAssertEqual(lifecycle.events, [], "nothing is wiped while the session may still be on this phone")
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
        await auth.signOut()

        XCTAssertEqual(auth.message, AnimalTracker.AuthError.sessionStillPresent.errorDescription)
        XCTAssertNotEqual(auth.state, .signedOut)
        XCTAssertEqual(lifecycle.events, [])
    }

    /// A sign-out that completes really does take the session item with it.
    func testSignOutRemovesThePinnedSessionItem() async throws {
        try sessionStorage.store(key: AuthService.sessionStorageKey, value: Data("session".utf8))
        let auth = makeService()
        await auth.signOut()
        XCTAssertNil(try sessionStorage.retrieve(key: AuthService.sessionStorageKey))
        XCTAssertEqual(auth.state, .signedOut)
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
        XCTAssertNotEqual(try auth.beginSignIn(), try auth.beginSignIn())
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
        XCTAssertEqual(lifecycle.events, [], "nothing may be cancelled or wiped without a client")
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
        XCTAssertTrue(first is AnimalTracker.AuthError, "a mismatch is reported as AuthError.nonceMismatch, got \(first)")
        XCTAssertEqual(auth.nonceEncodingForNextAttempt, .base64url, "the fallback is tried next")
        XCTAssertNil(defaults.string(forKey: NonceEncoding.defaultsKey),
                     "nothing is persisted until a sign-in actually succeeds")

        _ = auth.resolveSignInFailure(ServerNonceMismatch())
        XCTAssertEqual(auth.nonceEncodingForNextAttempt, .hex, "the fallback is exhausted, so hex comes back")
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
        XCTAssertTrue(lifecycle.events.contains(.wipeStore), "a real revocation is the one case that wipes")
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
