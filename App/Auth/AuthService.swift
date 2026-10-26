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

/// `Equatable` so `SignOutOutcome` can be, and so a test can assert the case rather than the type.
/// No case carries an associated value, which is what keeps a server string out of `message`.
enum AuthError: Error, LocalizedError, Equatable {
    case notConfigured
    case missingIdentityToken
    case nonceUnavailable
    case nonceMismatch
    case signInAlreadyInProgress
    case sessionNotPersisted
    case ownershipNotRecorded
    case signOutRefused
    case signOutAlreadyRunning
    case sessionStillPresent
    case sessionSurvivedSignOut
    case accountDeletionIncomplete

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
        case .signInAlreadyInProgress:
            return "A sign-in is already under way. Wait for it to finish."
        case .sessionNotPersisted:
            return "This phone could not save the sign-in. Try again."
        case .ownershipNotRecorded:
            return "This phone could not record who the records belong to. Try signing in again."
        case .signOutRefused:
            return "The server did not confirm the sign-out, but this phone is signed out."
        case .signOutAlreadyRunning:
            return "A sign-out is already under way. Wait for it to finish."
        case .sessionStillPresent:
            return "The session is still on this phone. You are still signed in. Try signing out again."
        case .sessionSurvivedSignOut:
            return "This phone signed out and your records here are gone, but a session file could not be removed. Restart the phone to finish clearing it."
        case .accountDeletionIncomplete:
            return "Your account was deleted. A session file could not be removed from this phone; restart the phone to finish clearing it."
        }
    }
}

/// What `signOut()` did, as data instead of only as a localized string.
///
/// `message` stays the human half; this is the machine-readable half, so Task 5 branches on the
/// case rather than comparing a string that any copy edit or localization breaks. Deliberately not
/// `throws`: `signOut()` has three callers and two of them, the revocation observer and the
/// `.revoked` probe, cannot act on a thrown error, so a throwing signature would force `try?` on
/// them, which is exactly the silent swallow the addendum condemns in the SDK's own storage
/// closures (`Sources/Auth/Internal/SessionStorage.swift:75-81`).
enum SignOutOutcome: Equatable {
    /// The session item is gone from the keychain. The only outcome that means signed out.
    case signedOut
    /// `.sessionStillPresent` is the keychain refusing before anything was destroyed: nothing was
    /// lost, the person is still signed in, and a lock and unlock or a restart usually clears it.
    /// `.sessionSurvivedSignOut` is the narrow race where a writer put the item back after the
    /// wipe: the local records are already gone and the retry marker is set.
    /// `.signOutAlreadyRunning` means a second tap arrived while the first sign-out was running.
    /// `.signOutRefused` never appears here; a server refusal is advice on `message`, not a
    /// refusal of the sign-out (RULING 2).
    case refused(AuthError)
}

/// A destructive transition the person asked for that could not be finished.
///
/// Persisted in `UserDefaults`, not the keychain, for the obvious reason: `UserDefaults` is
/// writable when the keychain is not, which is the exact condition this marker exists for. It is
/// what stops a relaunch silently forgetting that someone asked to sign out, and what stops the
/// app coming back signed in as a user that has already been deleted server-side.
enum PendingTeardown: String {
    case signOut
    case accountDeleted

    /// What to tell the person when the retry at launch also failed.
    var unfinishedMessage: String? {
        switch self {
        case .signOut: return AuthError.sessionStillPresent.errorDescription
        case .accountDeleted: return AuthError.accountDeletionIncomplete.errorDescription
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
    ///
    /// Throws when it cannot tell. The caller reads "could not tell" as "not empty", so a store
    /// that cannot be inspected is reset rather than adopted into the signing-in account. The
    /// throwing shape exists so an implementor cannot collapse a failed fetch into `true`, which
    /// would mean `.claimEmpty`, which would hand a populated store to a new account with no wipe
    /// and no watermark reset (RULING 4).
    func storeIsEmpty() throws -> Bool
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
    /// True while a sign-out is running. Separate from `isWorking`, which is documented as
    /// sign-in-scoped, and it is what stops two taps running two overlapping wipes.
    @Published private(set) var isSigningOut = false
    /// The one message the sign-in screen and Settings show. Never carries a server string.
    @Published var message: String?

    // The three defaults and keychain names below are `nonisolated`: they are immutable strings
    // with no isolation to protect, and code outside the main actor (a test, a future background
    // task) has to be able to name the items it looks for.
    nonisolated static let appleUserIDKey = "animalTracker.appleUserID"

    /// The keychain account the Supabase session occupies. Passed to the SDK as
    /// `AuthOptions.storageKey`, so this app knows the exact item rather than depending on the
    /// SDK's internal `defaultStorageKey`, so both destructive paths can read this exact item back
    /// and prove it is gone. Neither of them removes it by name any more: they sweep the service
    /// and then read this key and `codeVerifierStorageKey` back as the verification.
    nonisolated static let sessionStorageKey = "animalTracker.session"

    /// The second item the SDK keeps under the same service: the PKCE code verifier, named
    /// `<storageKey>-code-verifier`
    /// (https://github.com/supabase/supabase-swift/blob/v2.55.2/Sources/Auth/Internal/CodeVerifierStorage.swift).
    /// Both `signOut()` and `deleteAccount()` sweep the whole service rather than naming keys, and
    /// then read both of these back to prove the sweep worked.
    nonisolated static let codeVerifierStorageKey = "\(AuthService.sessionStorageKey)-code-verifier"

    /// Where a `PendingTeardown` is remembered between launches. `UserDefaults` and not the
    /// keychain, because the condition it records is a keychain that will not write.
    nonisolated static let pendingTeardownKey = "animalTracker.pendingTeardown"

    /// The bound on the final push an unattended sign-out attempts. The same 20 seconds the
    /// Settings button uses (`task-5-brief.md:703`), stated here so the two cannot drift. A dead
    /// network must not hang a sign-out on a sync-engine retry.
    nonisolated static let finalPushTimeout: TimeInterval = 20

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

    /// The final push an unattended sign-out attempts before anything is destroyed (RULING 3).
    ///
    /// A closure rather than a protocol call because `SyncCoordinating.pushBeforeSignOut(timeout:)`
    /// is declared in Task 5 and must not be declared twice. Task 5 sets this to
    /// `{ timeout in await store.sync?.pushBeforeSignOut(timeout: timeout) ?? true }`. Nil means no
    /// sync is attached, which is the same as nothing to push.
    var finalPushBeforeSignOut: (@MainActor (TimeInterval) async -> Bool)?

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
        //
        // `global` is deliberately absent, so `GlobalOptions.logger` keeps its nil default
        // (`Sources/Supabase/Types.swift:117-122`). That nil is load-bearing, not cosmetic:
        // `LiveSessionManager.refreshSession` puts the raw refresh token into the logger's
        // task-local context (`Sources/Auth/Internal/SessionManager.swift:68-72`), and the SDK's
        // request logging would write the body of `POST /token?grant_type=id_token`, which carries
        // the Apple identity token and the raw nonce. Anyone who adds a logger here to debug a
        // sync problem starts writing credentials wherever that logger writes.
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
        // A sign-out or an account deletion the keychain refused is finished here, before any
        // session is restored. Without this the person's intent is lost on relaunch: the item is
        // still on disk, `currentSession` is non-nil, and `establish()` presents the tabs as a
        // normal session, or as a user that no longer exists server-side.
        if let pending = PendingTeardown(rawValue: defaults.string(forKey: AuthService.pendingTeardownKey) ?? "") {
            await finishPendingTeardown(pending)
            return
        }
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
        // `?? false` is the fail-closed default for `storeIsEmpty`, and it now covers two kinds of
        // "unknown" rather than one. With no lifecycle attached there is no way to ask whether the
        // store holds anything; with a lifecycle that throws, the store exists but could not be
        // inspected. Both have to mean "assume it holds someone's records", so an unowned store is
        // reset rather than adopted into this account. `?? true` would silently hand the previous
        // person's data to whoever signs in next. `try?` flattens here (SE-0230), so this is a
        // single `Bool?`, not a nested one.
        let decision = StoreOwnerPolicy.decision(ownership: StoreOwner.loadOutcome(defaults: defaults),
                                                 newUserID: userID,
                                                 storeIsEmpty: (try? lifecycle?.storeIsEmpty()) ?? false)
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
        // store nobody claims. And it is read back, like every other load-bearing write in this
        // file: `StoreOwner.save` is silent on both of its failure modes (`App/Sync/SyncState.swift:260-261`
        // encodes with `try?` and then calls a bare `defaults.set`), and in the unreadable-record
        // case the fresh claim is the only thing that restores the mismatch guard for the next
        // person who signs in on this phone. A claim that did not stick must not reach sync.
        let claim = StoreOwner(userID: userID.uuidString.lowercased(), claimedAt: Date())
        claim.save(defaults: defaults)
        guard case .decoded(let written) = StoreOwner.loadOutcome(defaults: defaults),
              written.userID == claim.userID else {
            state = .signedOut
            message = AuthError.ownershipNotRecorded.errorDescription
            lifecycle?.configureSync(for: state, client: client)
            return
        }
        state = .signedIn(userID: userID, email: email)
        lifecycle?.configureSync(for: state, client: client)
    }

    // MARK: sign in

    /// Prepares an authorization request. Returns the digest Apple is given; the raw nonce stays
    /// here. Throws rather than returning a predictable value, so a device that cannot produce
    /// randomness fails the sign-in instead of weakening it.
    func beginSignIn() throws -> String {
        // One attempt at a time. A second tap would overwrite `pendingRawNonce`, so the first
        // authorization's completion would be exchanged against the second nonce and rejected by
        // the server, which reads as a nonce mismatch and moves the digest encoding on for a
        // mistake made entirely on this side.
        guard !isWorking else { throw AuthError.signInAlreadyInProgress }
        let raw = try Nonce.random()
        pendingRawNonce = raw
        message = nil
        isWorking = true
        return Nonce.digest(raw, encoding: nonceEncoding)
    }

    /// Called when the attempt ended without a credential this app can exchange. That covers the
    /// request that could not be prepared, an `ASAuthorizationError`, and the commonest case of
    /// all: the person opened the Apple sheet and dismissed it.
    ///
    /// `SignInWithAppleButton` reports a cancel as `.failure(ASAuthorizationError.canceled)` to
    /// `onCompletion`, so `signInWithApple(authorization:)` is never called and nothing else clears
    /// `isWorking` or the pending nonce. **Task 5's `onCompletion` must call this from its
    /// `.failure` branch, cancels included**, or the sign-in button stays busy and the raw nonce
    /// stays live until the app is relaunched. Pass an empty message for a cancel: there is nothing
    /// to tell someone who just decided not to sign in.
    func abortSignIn(message: String) {
        pendingRawNonce = nil
        isWorking = false
        // An empty string means "say nothing", not "show a blank line of red text".
        self.message = message.isEmpty ? nil : message
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
            // The other half of addendum obligation 1, on the way in rather than the way out.
            // `SessionStorage.store` swallows a keychain write failure in a non-throwing closure
            // that only logs (`Sources/Auth/Internal/SessionStorage.swift:65-74`), so
            // `signInWithIdToken` returning a `Session` is not evidence that the session reached
            // the keychain. Without this read-back the sign-in works for the lifetime of the
            // process and is silently gone at the next launch. A throwing retrieve is also a
            // failure, which is why this is `try?` and a nil test rather than a `do`/`catch`.
            if ((try? sessionStorage.retrieve(key: AuthService.sessionStorageKey)) ?? nil) == nil {
                throw AuthError.sessionNotPersisted
            }
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
    ///
    /// **The keychain is the authority on whether this worked, not the SDK** (RULING 2, and the
    /// global constraint added during execution). Addendum v7.1 says sign-out "does not proceed if
    /// the SDK sign-out fails", and the letter of that sentence is now known to be wrong: it was
    /// written assuming a thrown `AuthClient.signOut` means the local session survived, and it
    /// does not. `AuthClient.signOut` deletes the local session at
    /// `Sources/Auth/AuthClient.swift:1101`, *before* the network call at `:1106`, and its only
    /// `catch` absorbs `AuthError.api` with 401, 403 or 404 (`:1114-1119`). Everything else
    /// propagates after the session is already gone: an offline tap, a timeout, a 5xx, and, most
    /// ordinarily, a session the server has already terminated, because
    /// `APIClient.handleError` returns `.sessionMissing` rather than `.api` for the four
    /// session-cleanup codes (`Sources/Auth/Internal/APIClient.swift:43-48`, `:117-123`). The old
    /// code answered all of those with "You are still signed in", which was false on both clauses,
    /// and left the tabs up with no session and sync broken.
    ///
    /// So an SDK throw is recorded and may be surfaced as advice; it does not by itself abort the
    /// wipe. Only a session item that is still present after the removal attempt aborts. Do not
    /// "restore" the old behaviour.
    @discardableResult
    func signOut() async -> SignOutOutcome {
        // F12: two taps must not run two overlapping wipes. There is a network call, a cancel and
        // a wipe to suspend in.
        guard !isSigningOut else { return .refused(.signOutAlreadyRunning) }
        isSigningOut = true
        defer { isSigningOut = false }
        message = nil
        // Written before anything destructive, so a refusal survives a relaunch and is retried.
        defaults.set(PendingTeardown.signOut.rawValue, forKey: AuthService.pendingTeardownKey)

        // F1, Critical. Every writer of the session item stops before the item is removed.
        // `stopAutoRefresh()` first: the loop is on by default (`Sources/Auth/Defaults.swift:35`,
        // `Sources/Supabase/Types.swift:92`), is started on `didBecomeActive`
        // (`Sources/Auth/AuthClient.swift:305-313`), ticks every 30 seconds
        // (`Sources/Auth/Internal/Constants.swift:14`) and writes the keychain through
        // `update(session)` -> `sessionStorage.store` (`Sources/Auth/Internal/SessionManager.swift:102`,
        // `:113-115`). Then `cancelSync()`: every PostgREST and Storage request takes its token
        // from `auth.session` (`Sources/Supabase/SupabaseClient.swift:464-471`), which refreshes
        // and writes through the same path. A request already awaiting the network when the
        // sign-out starts is otherwise free to land after the read-back and leave a live session on
        // disk under a wiped store, and the next launch signs the person back in.
        await client?.auth.stopAutoRefresh()
        await lifecycle?.cancelSync()

        var serverRefused = false
        if let client {
            do {
                try await client.auth.signOut(scope: .local)
            } catch {
                serverRefused = true
            }
        }

        // The decision point. The keychain, read back, is the gate.
        do {
            try clearAllSessionItems()
        } catch {
            // Nothing was destroyed and nothing may be. Put the writers back so the person is not
            // left signed in with sync dead until the next launch.
            await client?.auth.startAutoRefresh()
            lifecycle?.configureSync(for: state, client: client)
            message = AuthError.sessionStillPresent.errorDescription
            return .refused(.sessionStillPresent)
        }

        await lifecycle?.wipeStore()

        // `stopAutoRefresh()` is fire and forget (`Sources/Auth/AuthClient.swift:1525-1527` wraps
        // it in a detached `Task`) and it does not cancel `inFlightRefreshTask`
        // (`Sources/Auth/Internal/SessionManager.swift:75-78`), so a refresh that was already
        // awaiting the network can still write a fresh session after the read-back above. Check
        // once more and take it with us.
        var itemCameBack = false
        do {
            try clearAllSessionItems()
        } catch {
            itemCameBack = true
        }

        SyncState.clear(defaults: defaults)
        StoreOwner.clear(defaults: defaults)
        defaults.removeObject(forKey: AuthService.appleUserIDKey)
        state = .signedOut
        lifecycle?.configureSync(for: state, client: client)

        if itemCameBack {
            // The store is already gone, so staying signed in protects nothing. The pending marker
            // stays set instead: the next launch retries the removal before establishing anything,
            // which is what stops the surviving session from signing the person back in. A
            // distinct case, because `.sessionStillPresent` says "you are still signed in" and
            // here the person is not.
            message = AuthError.sessionSurvivedSignOut.errorDescription
            return .refused(.sessionSurvivedSignOut)
        }
        defaults.removeObject(forKey: AuthService.pendingTeardownKey)
        if serverRefused {
            // Advice, not a failure. The token bytes are off this phone and `.local` scope never
            // touched another device, so the only residue is a refresh token the server may not
            // have revoked.
            message = AuthError.signOutRefused.errorDescription
        }
        return .signedOut
    }

    /// Finishes a destructive transition a previous run could not complete (F3).
    ///
    /// Called from `restoreSession()` before anything is established. A sign-out whose keychain
    /// removal was refused never ran its destructive half, so that still has to happen; a deletion
    /// already ran it, and wiping an empty store again costs nothing. If the keychain is still
    /// refusing, nothing is destroyed and nothing is established: the person is shown the pending
    /// state rather than being signed back in as themselves or as a deleted user.
    private func finishPendingTeardown(_ pending: PendingTeardown) async {
        await client?.auth.stopAutoRefresh()
        await lifecycle?.cancelSync()
        var swept = true
        do {
            try clearAllSessionItems()
        } catch {
            swept = false
        }
        if swept {
            await lifecycle?.wipeStore()
            SyncState.clear(defaults: defaults)
            StoreOwner.clear(defaults: defaults)
            defaults.removeObject(forKey: AuthService.appleUserIDKey)
            defaults.removeObject(forKey: AuthService.pendingTeardownKey)
        } else {
            message = pending.unfinishedMessage
        }
        state = .signedOut
        lifecycle?.configureSync(for: state, client: client)
    }

    /// Sweeps every item under this app's keychain service and proves the two it knows about are
    /// gone. **Both destructive paths use this**, and this is the only thing either of them treats
    /// as evidence.
    ///
    /// "signOut did not throw" is evidence of nothing. The SDK's `SessionStorage` wraps `store` and
    /// `remove` in non-throwing closures that only log
    /// (`Sources/Auth/Internal/SessionStorage.swift:65-74`, `:75-81`) and `SessionManager.remove`
    /// is itself non-throwing (`:117-119`), so `AuthClient.signOut` cannot fail when the keychain
    /// write fails; it also returns early without touching the keychain at all when
    /// `currentSession?.accessToken` is nil (`Sources/Auth/AuthClient.swift:1095-1098`). Either way
    /// the item can survive a sign-out that reported success. So the removal happens here, its
    /// throw is not swallowed, and the items are read back.
    ///
    /// A sweep rather than a `remove(key:)` on both paths, for three reasons: the PKCE code
    /// verifier is a transient auth secret and does not belong on the phone after a sign-out; one
    /// service-wide `SecItemDelete` cannot drift as the SDK adds keys; and it is the only form that
    /// also takes the legacy `"supabase.session"` account, which `StorageMigration.sessionNewKey`
    /// copies into the pinned key on *every* `currentSession` read
    /// (`Sources/Auth/Internal/SessionStorage.swift:44-53`, `:94-105`), so a named removal has a
    /// latent resurrection path behind it.
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
        // F1 on this path too: the auto-refresh loop writes the session item every 30 seconds and
        // nothing else stops it.
        await client.auth.stopAutoRefresh()
        await lifecycle?.cancelSync()
        do {
            try await client.rpc(ServerFunctions.deleteMyAccount).execute()
        } catch {
            // The account still exists and nothing local has changed, so this is a clean retry.
            // But sync and the refresh loop were stopped a line ago and `state` is still
            // `.signedIn`, so without this the tabs keep working against a live session with sync
            // silently dead until the next launch (A5). Reconfigure on the way out.
            await client.auth.startAutoRefresh()
            lifecycle?.configureSync(for: state, client: client)
            throw error
        }
        // The account is gone server-side from here on, so the local teardown has to finish even
        // across a relaunch: the marker is what stops the next launch establishing a deleted user.
        defaults.set(PendingTeardown.accountDeleted.rawValue, forKey: AuthService.pendingTeardownKey)
        try? await client.auth.signOut(scope: .local)
        var keychainFailure: (any Error)?
        do {
            try clearAllSessionItems()
        } catch {
            keychainFailure = error
            // Not the sign-out copy: there is no account left to sign out of, and "try signing out
            // again" would contradict the message Task 5 shows for the throw below.
            message = AuthError.accountDeletionIncomplete.errorDescription
        }
        await lifecycle?.wipeStore()
        // The same post-wipe re-check `signOut()` does, for the same reason: `stopAutoRefresh()`
        // does not cancel a refresh already in flight, so the item can be written back after the
        // sweep was verified.
        if keychainFailure == nil {
            do {
                try clearAllSessionItems()
            } catch {
                keychainFailure = error
                message = AuthError.accountDeletionIncomplete.errorDescription
            }
        }
        SyncState.clear(defaults: defaults)
        StoreOwner.clear(defaults: defaults)
        defaults.removeObject(forKey: AuthService.appleUserIDKey)
        if keychainFailure == nil {
            defaults.removeObject(forKey: AuthService.pendingTeardownKey)
        }
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
                // The same two preconditions `checkAppleCredentialState()` already applies. Without
                // them a revocation notification reaches the full destructive path from any state,
                // including `.misconfigured`, where `client` is nil, the keychain removal deletes
                // nothing and does not throw, and the wipe runs anyway: a blocking "not configured"
                // screen becomes a sign-in screen that cannot sign in, with the person's local
                // records gone. A revocation is meaningless in a state that never held an Apple
                // credential.
                await self?.handleCredentialRevocation()
            }
        }
    }

    /// The body of the revocation observer, factored out of the closure so the guard is testable
    /// without posting a notification and waiting on a queue hop.
    ///
    /// Internal, not private, for that reason only. Nothing but the observer should call it.
    func handleCredentialRevocation() async {
        // The same two preconditions `checkAppleCredentialState()` already applies. Without them a
        // revocation notification reaches the full destructive path from any state, including
        // `.misconfigured`, where `client` is nil, the keychain sweep deletes nothing and does not
        // throw, and the wipe runs anyway: a blocking "not configured" screen becomes a sign-in
        // screen that cannot sign in, with the person's local records gone. A revocation is
        // meaningless in a state that never held an Apple credential.
        guard case .signedIn = state,
              defaults.string(forKey: AuthService.appleUserIDKey) != nil else { return }
        await signOutAfterRevocation()
    }

    /// A sign-out nobody is watching: the Apple credential was revoked.
    ///
    /// RULING 3. Revoking an Apple credential does not invalidate the Supabase session, so the
    /// refresh token is still good and the final push would usually succeed, which means the old
    /// behaviour destroyed every record created since the last sync, unattended. So this attempts
    /// the same final push a user-initiated sign-out does, with the same bound, and then proceeds
    /// whatever the push returned. It never asks: there is nobody looking at the phone, so a
    /// confirmation dialog is not available, and a revoked credential is not a decision to defer.
    private func signOutAfterRevocation() async {
        _ = await finalPushBeforeSignOut?(AuthService.finalPushTimeout)
        await signOut()
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
            await signOutAfterRevocation()
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
