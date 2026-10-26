import AuthenticationServices
import Foundation
import Supabase

enum AuthState: Equatable {
    /// Before the first session restore finishes.
    case unknown
    case signedOut
    case signedIn(userID: UUID, email: String?)
    /// DEBUG "Continue offline".
    case offline
    /// A build that shipped without a usable anon key. Release shows a blocking screen; the tabs
    /// are never reachable from here.
    case misconfigured
}

enum AuthError: Error, LocalizedError {
    case notConfigured
    case missingIdentityToken
    case nonceUnavailable
    case nonceMismatch
    case signOutRefused
    case sessionStillPresent

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "This build has no Supabase anon key, so it cannot sign in."
        case .missingIdentityToken:
            return "Apple did not return an identity token."
        case .nonceUnavailable:
            return "This sign-in could not be prepared securely. Tap the button again."
        case .nonceMismatch:
            return "The server did not accept the sign-in check. Tap the button again."
        case .signOutRefused:
            return "The server refused the sign-out. You are still signed in."
        case .sessionStillPresent:
            return "The session is still on this phone. Try signing out again."
        }
    }
}

/// What AuthService does to the local store, in order, at each transition. It exists so the order
/// is one function's business rather than the emergent result of two SwiftUI `.onChange` handlers
/// whose relative ordering is not defined.
@MainActor
protocol StoreLifecycle: AnyObject {
    /// Stops any running sync and waits for it to actually stop.
    func cancelSync() async
    /// True when the store holds no user records at all.
    func storeIsEmpty() -> Bool
    /// Destroys the store, opens a fresh one, re-seeds it and republishes it to the UI.
    func wipeStore() async
    /// Points sync at this state's user and client, or at nothing.
    func configureSync(for state: AuthState, client: SupabaseClient?)
}

/// The session storage, with the one operation `AuthLocalStorage` does not have.
///
/// `AuthService` clears the session item itself rather than trusting the SDK's `signOut` to have
/// done it, so the storage has to be substitutable: a keychain that refuses a delete is the one
/// failure the SDK cannot report, and it has to be driveable in a test.
protocol SessionItemStore: AuthLocalStorage {
    /// Removes every item under this storage's service, not just one key.
    func removeAll() throws
}

extension KeychainSessionStorage: SessionItemStore {}

@MainActor
final class AuthService: ObservableObject {
    @Published private(set) var state: AuthState = .unknown
    /// True from the moment the Sign in with Apple request is prepared until the exchange finishes.
    @Published private(set) var isWorking = false
    /// The one message the sign-in screen and Settings show. Never carries a server string.
    @Published var message: String?

    // The three defaults and keychain names below are `nonisolated`: they are immutable strings
    // with no isolation to protect, and code outside the main actor (a test, a future background
    // task) has to be able to name the items it looks for.
    nonisolated static let appleUserIDKey = "animalTracker.appleUserID"

    /// The keychain account the Supabase session occupies. Passed to the SDK as
    /// `AuthOptions.storageKey`, so this app knows the exact item rather than depending on the
    /// SDK's internal `defaultStorageKey`. `signOut()` removes this item by name.
    nonisolated static let sessionStorageKey = "animalTracker.session"

    /// The second item the SDK keeps under the same service: the PKCE code verifier, named
    /// `<storageKey>-code-verifier`
    /// (https://github.com/supabase/supabase-swift/blob/v2.55.2/Sources/Auth/Internal/CodeVerifierStorage.swift).
    /// `deleteAccount()` sweeps the whole service rather than naming keys, and then reads both of
    /// these back to prove the sweep worked.
    nonisolated static let codeVerifierStorageKey = "\(AuthService.sessionStorageKey)-code-verifier"

    /// True in a build without DEBUG. Injectable so the fail-closed behaviour is testable.
    ///
    /// `nonisolated` because it is the default value of an `init` parameter, and a default argument
    /// is evaluated in the caller's context, which is not this class's actor. It reads a compile
    /// flag and no state, so it is safe anywhere.
    nonisolated static var isReleaseBuild: Bool {
        #if DEBUG
        return false
        #else
        return true
        #endif
    }

    let client: SupabaseClient?

    /// The options the client is built with, recorded whether or not a client was built. There is
    /// exactly one of these and `client`, if any, was constructed from it, so asserting on it is
    /// the same as asserting on the client's own configuration, with no client and no network
    /// needed to do it. It is what pins the session to this app's keychain service.
    let clientOptions: SupabaseClientOptions

    /// Set once by the app at launch. Weak: the app owns it, this service only drives it.
    weak var lifecycle: (any StoreLifecycle)?

    /// The same storage the client was built with, so the destructive paths can remove the session
    /// item themselves rather than trusting `signOut` to have done it.
    let sessionStorage: any SessionItemStore

    private let defaults: UserDefaults
    private let isRelease: Bool
    /// Held between preparing the Apple request and the completion coming back. Cleared as soon as
    /// it is used, so one nonce can never serve two authorizations. Private, and nothing hands the
    /// raw value out: `beginSignIn()` returns the digest only.
    private var pendingRawNonce: String?
    private var nonceEncoding: NonceEncoding
    private var revocationObserver: (any NSObjectProtocol)?

    init(config: SupabaseConfig? = SupabaseConfig.load(),
         defaults: UserDefaults = .standard,
         isRelease: Bool = AuthService.isReleaseBuild,
         sessionStorage: any SessionItemStore = KeychainSessionStorage()) {
        self.defaults = defaults
        self.isRelease = isRelease
        self.nonceEncoding = NonceEncoding.load(defaults: defaults)
        self.sessionStorage = sessionStorage
        // One options value, built once and kept, so "the storage the client uses" and "the
        // storage this service clears" cannot drift apart.
        let options = SupabaseClientOptions(
            db: .init(encoder: SyncCoding.encoder, decoder: SyncCoding.decoder),
            // storageKey is pinned rather than left to the SDK's internal `defaultStorageKey`, so
            // the sign-out and account deletion paths can name the items they have to remove.
            auth: .init(storage: sessionStorage, storageKey: AuthService.sessionStorageKey)
        )
        clientOptions = options
        client = config.map {
            SupabaseClient(supabaseURL: $0.url, supabaseKey: $0.anonKey, options: options)
        }
    }

    var isConfigured: Bool { client != nil }

    /// The encoding the next sign-in request will use. A read-only view of the preference, so the
    /// rule "nothing is persisted until a sign-in works" is testable without exposing the nonce.
    var nonceEncodingForNextAttempt: NonceEncoding { nonceEncoding }

    // MARK: launch

    /// Restores the session the SDK persisted. `currentSession` is read first, and only a
    /// genuinely absent session means signed out: a refresh that fails because the phone is on a
    /// train must not throw the person back to the sign-in screen.
    func restoreSession() async {
        guard let client else {
            state = isRelease ? .misconfigured : .offline
            lifecycle?.configureSync(for: state, client: nil)
            return
        }
        guard let stored = client.auth.currentSession else {
            state = .signedOut
            lifecycle?.configureSync(for: state, client: client)
            return
        }
        do {
            let fresh = try await client.auth.session
            await establish(userID: fresh.user.id, email: fresh.user.email)
        } catch {
            if client.auth.currentSession == nil {
                // The SDK dropped the session: the refresh token really is dead.
                state = .signedOut
                lifecycle?.configureSync(for: state, client: client)
            } else {
                // Network or server trouble with a session still on the phone. Carry on signed in
                // and let the next request refresh lazily.
                await establish(userID: stored.user.id, email: stored.user.email)
            }
        }
        await checkAppleCredentialState()
    }

    // MARK: the one ordered transition

    /// Everything that has to happen between "there is a session" and "the UI may show records",
    /// in the only order that is safe. Internal rather than private so the ordering is testable
    /// without a network.
    func establish(userID: UUID, email: String?) async {
        // The three-case entry point, not the sentinel-carrying one-argument form: a record that
        // is present and unreadable is a fault, never a fresh install, and it must not reach
        // `.reset`.
        //
        // `?? false` is the fail-closed default for `storeIsEmpty`. With no lifecycle attached
        // there is no way to ask whether the store holds anything, and "unknown" has to mean
        // "assume it holds someone's records", so an unowned store is reset rather than adopted
        // into this account. `?? true` would silently hand the previous person's data to whoever
        // signs in next.
        let decision = StoreOwnerPolicy.decision(ownership: StoreOwner.loadOutcome(defaults: defaults),
                                                 newUserID: userID,
                                                 storeIsEmpty: lifecycle?.storeIsEmpty() ?? false)
        switch decision {
        case .keep:
            break
        case .claimEmpty:
            var syncState = SyncState.load(defaults: defaults)
            syncState.forgetSyncHistory()
            syncState.save(defaults: defaults)
        case .reset:
            await lifecycle?.cancelSync()
            await lifecycle?.wipeStore()
            SyncState.clear(defaults: defaults)
        }
        // Ownership is recorded before any sync runs, so a crash mid-sync cannot leave rows in a
        // store nobody claims.
        StoreOwner(userID: userID.uuidString.lowercased(), claimedAt: Date()).save(defaults: defaults)
        state = .signedIn(userID: userID, email: email)
        lifecycle?.configureSync(for: state, client: client)
    }

    // MARK: sign in

    /// Prepares an authorization request. Returns the digest Apple is given; the raw nonce stays
    /// here. Throws rather than returning a predictable value, so a device that cannot produce
    /// randomness fails the sign-in instead of weakening it.
    func beginSignIn() throws -> String {
        let raw = try Nonce.random()
        pendingRawNonce = raw
        message = nil
        isWorking = true
        return Nonce.digest(raw, encoding: nonceEncoding)
    }

    /// Called when the request could not be prepared. Drops the pending nonce so a completion that
    /// still arrives cannot be exchanged.
    func abortSignIn(message: String) {
        pendingRawNonce = nil
        isWorking = false
        self.message = message
    }

    func signInWithApple(authorization: ASAuthorization) async throws {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let idToken = String(data: tokenData, encoding: .utf8) else {
            // Fail closed: a credential this app cannot read also burns the nonce, so nothing can
            // be retried with the half-finished request.
            pendingRawNonce = nil
            isWorking = false
            throw AuthError.missingIdentityToken
        }
        // Apple hands back the email only on the very first authorization, so it is passed on as a
        // fallback for the session's own.
        try await exchange(idToken: idToken, appleUserID: credential.user, email: credential.email)
    }

    /// The exchange itself, with the one thing no unit test can build already unwrapped.
    /// `ASAuthorization` has no public initializer, so this is the seam that makes the nonce
    /// lifetime, the encoding rule and the ordered transition testable without an Apple account.
    func exchange(idToken: String, appleUserID: String, email: String?) async throws {
        defer { isWorking = false }
        // The nonce is taken first and unconditionally: one nonce serves exactly one authorization,
        // whatever becomes of it. A failed exchange therefore cannot be retried with the identity
        // token Apple already signed, because the digest in that token was computed from this
        // nonce under the encoding that just failed. A retry has to start again at
        // `beginSignIn()`, which asks Apple for a fresh authorization.
        guard let rawNonce = pendingRawNonce else { throw AuthError.nonceUnavailable }
        pendingRawNonce = nil
        guard let client else { throw AuthError.notConfigured }
        let encoding = nonceEncoding
        do {
            let session = try await client.auth.signInWithIdToken(
                credentials: OpenIDConnectCredentials(provider: .apple, idToken: idToken, nonce: rawNonce)
            )
            // Only a sign-in that actually worked persists the encoding. Writing it from the
            // failure path is what could pin the app to base64url for good, since
            // `base64url.next` is nil and nothing else ever writes hex back.
            encoding.save(defaults: defaults)
            // Apple's opaque user id is what credential revocation is checked against later.
            defaults.set(appleUserID, forKey: AuthService.appleUserIDKey)
            await establish(userID: session.user.id, email: session.user.email ?? email)
        } catch {
            throw resolveSignInFailure(error)
        }
    }

    /// Turns a failed exchange into the error to throw, and moves the digest encoding on when the
    /// server rejected the nonce.
    ///
    /// The preference is never persisted here. A mismatch switches the encoding in memory, so the
    /// next attempt tries the other one; an attempt that fails with the fallbacks exhausted puts
    /// hex back, in memory and on disk, because hex is the correct primary (GoTrue compares
    /// `fmt.Sprintf("%x", sha256.Sum256(...))`) and `base64url.next` is nil, so an app pinned
    /// there has no way home. `isNonceMismatch` matches on the message text, which is all the
    /// server gives, so it has false positives by construction; this shape makes the cost of one
    /// a single retry rather than a permanent setting.
    ///
    /// Internal so the rule is testable without an `ASAuthorization`.
    func resolveSignInFailure(_ error: any Error) -> any Error {
        guard AuthService.isNonceMismatch(error) else { return error }
        if let next = nonceEncoding.next {
            nonceEncoding = next
        } else {
            nonceEncoding = .hex
            NonceEncoding.hex.save(defaults: defaults)
        }
        return AuthError.nonceMismatch
    }

    /// The only signal Supabase gives is the message text. Matching on it is crude, but the
    /// consequence of a false positive is one retry with the other digest encoding, which is
    /// harmless, and there is no error code to match on instead.
    static func isNonceMismatch(_ error: any Error) -> Bool {
        let text = "\(error) \(error.localizedDescription)".lowercased()
        return text.contains("nonce")
    }

    // MARK: sign out and deletion

    /// Local scope: signing out of this phone never kills the person's session on another device.
    /// A refused sign-out leaves the person signed in with a message rather than wiping a store
    /// whose session is still live.
    func signOut() async {
        message = nil
        if let client {
            do {
                try await client.auth.signOut(scope: .local)
            } catch {
                message = AuthError.signOutRefused.errorDescription
                return
            }
        }
        do {
            try clearSessionItem()
        } catch {
            message = AuthError.sessionStillPresent.errorDescription
            return
        }
        if client?.auth.currentSession != nil {
            message = AuthError.sessionStillPresent.errorDescription
            return
        }
        await lifecycle?.cancelSync()
        await lifecycle?.wipeStore()
        SyncState.clear(defaults: defaults)
        StoreOwner.clear(defaults: defaults)
        defaults.removeObject(forKey: AuthService.appleUserIDKey)
        state = .signedOut
        lifecycle?.configureSync(for: state, client: client)
    }

    /// Removes the session item by name and proves it is gone.
    ///
    /// "signOut did not throw" is not evidence of anything. The SDK's `SessionStorage` wraps
    /// `store` and `remove` in non-throwing closures that only log, and `SessionManager.remove()`
    /// is itself non-throwing, so `AuthClient.signOut` cannot fail when the keychain write fails;
    /// it also returns early, without touching the keychain at all, when `currentSession?.accessToken`
    /// is nil. Either way the item can survive a sign-out that reported success, and the next
    /// launch restores it. So the removal happens here, its throw is not swallowed, and the item
    /// is read back.
    private func clearSessionItem() throws {
        try sessionStorage.remove(key: AuthService.sessionStorageKey)
        if try sessionStorage.retrieve(key: AuthService.sessionStorageKey) != nil {
            throw AuthError.sessionStillPresent
        }
    }

    /// Sweeps every item under this app's keychain service and proves the two it knows about are
    /// gone. Used by account deletion, where leaving the PKCE code verifier behind would leave a
    /// fragment of a deleted account on the phone.
    private func clearAllSessionItems() throws {
        try sessionStorage.removeAll()
        let session = try sessionStorage.retrieve(key: AuthService.sessionStorageKey)
        let codeVerifier = try sessionStorage.retrieve(key: AuthService.codeVerifierStorageKey)
        if session != nil || codeVerifier != nil {
            throw AuthError.sessionStillPresent
        }
    }

    /// Deletes the account server-side and then leaves the phone in a fresh-install state.
    ///
    /// The sign-out is best effort, because once `delete_my_account()` has returned the auth user
    /// is gone and `/logout` answers 401 or 403. The keychain is not best effort. It is swept, the
    /// result is checked, and a failure is reported by throwing, which happens *after* the local
    /// wipe: the account really is gone server-side, so the store has to be cleared whatever the
    /// keychain does, and the person must still not be told the deletion finished cleanly when a
    /// session item survived on this phone.
    func deleteAccount() async throws {
        guard let client else { throw AuthError.notConfigured }
        isWorking = true
        defer { isWorking = false }
        await lifecycle?.cancelSync()
        try await client.rpc(ServerFunctions.deleteMyAccount).execute()
        try? await client.auth.signOut(scope: .local)
        var keychainFailure: (any Error)?
        do {
            try clearAllSessionItems()
        } catch {
            keychainFailure = error
            message = AuthError.sessionStillPresent.errorDescription
        }
        await lifecycle?.wipeStore()
        SyncState.clear(defaults: defaults)
        StoreOwner.clear(defaults: defaults)
        defaults.removeObject(forKey: AuthService.appleUserIDKey)
        state = .signedOut
        lifecycle?.configureSync(for: state, client: client)
        if let keychainFailure { throw keychainFailure }
    }

    /// Leaves DEBUG offline mode. The offline data is discarded: nobody owns it, and adopting it
    /// into the next account is exactly what `StoreOwnerPolicy` refuses to do.
    func leaveOfflineMode() async {
        await lifecycle?.cancelSync()
        await lifecycle?.wipeStore()
        SyncState.clear(defaults: defaults)
        StoreOwner.clear(defaults: defaults)
        state = .signedOut
        lifecycle?.configureSync(for: state, client: client)
    }

    #if DEBUG
    /// Simulator and review builds: reach the tabs without an Apple account.
    func continueOffline() {
        state = .offline
        lifecycle?.configureSync(for: state, client: client)
    }
    #endif

    // MARK: Apple credential revocation

    /// Called once by the app at launch. Never torn down: AuthService lives for the whole process.
    func startWatchingAppleCredential() {
        guard revocationObserver == nil else { return }
        revocationObserver = NotificationCenter.default.addObserver(
            forName: ASAuthorizationAppleIDProvider.credentialRevokedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.signOut()
            }
        }
    }

    /// Asks Apple whether the person has revoked this app's access since last launch.
    ///
    /// **Only `.revoked` signs out.** `.revoked` is an unambiguous decision the person made in iOS
    /// Settings. Nothing else is. `.notFound` is what the API also returns when the Apple ID signed
    /// in on the device is not the one this id belongs to, which covers switching Apple IDs, a
    /// restored device, and, per the API contract, the error path; `.transferred` means the app was
    /// transferred between developer accounts and the credential has to be migrated, not destroyed.
    /// A thrown or returned error means "could not determine", and the only safe response to "could
    /// not determine" is to do nothing: the next authenticated request will find out for certain,
    /// and it cannot delete anything. Acting on the ambiguous cases would buy signing out slightly
    /// sooner and would cost an irreversible local wipe (verification defect D-D8).
    func checkAppleCredentialState() async {
        guard case .signedIn = state,
              let appleUserID = defaults.string(forKey: AuthService.appleUserIDKey) else { return }
        let (credentialState, error) = await credentialStateProbe(appleUserID)
        if let error {
            // Could not determine. Leave the session and the store exactly as they are.
            message = nil
            AuthService.log("credential state undetermined for this Apple id: \(error.localizedDescription)")
            return
        }
        switch credentialState {
        case .revoked:
            await signOut()
        case .notFound, .transferred:
            AuthService.log("credential state \(credentialState.rawValue) is not a revocation; leaving the session and the store alone")
        default:
            break
        }
    }

    /// Seam for the test. Defaults to the real provider; `AuthServiceTests` substitutes a closure
    /// so the ambiguous outcomes can be driven without an Apple ID.
    var credentialStateProbe: (String) async -> (ASAuthorizationAppleIDProvider.CredentialState, (any Error)?)
        = AuthService.realCredentialState

    private static func realCredentialState(
        forUserID userID: String
    ) async -> (ASAuthorizationAppleIDProvider.CredentialState, (any Error)?) {
        await withCheckedContinuation { continuation in
            ASAuthorizationAppleIDProvider().getCredentialState(forUserID: userID) { credentialState, error in
                continuation.resume(returning: (credentialState, error))
            }
        }
    }

    /// One place for the two diagnostic lines above. Deliberately not `os_log`: nothing in this
    /// file may write an identity token, a session or an Apple user id to a log, and a single
    /// funnel makes that reviewable.
    private static func log(_ line: String) {
        #if DEBUG
        print("[auth] \(line)")
        #endif
    }
}
